//! Building a container's LINE-ONLY address space from the container itself.
//!
//! A line-only `.ct` addresses each step with one integer that names one source
//! line. Which `(path_id, line)` it names is the spec's prefix sum over the
//! registered files in file-id order
//! (`codetracer-trace-format-spec/trace-events.md` §"Per-File Contiguous Integer
//! Ranges"), so inverting one needs the container's file count and the size of
//! each file's slot.
//!
//! The file count is in `paths.off`, the offset index of the path interning
//! table. The slot sizes are in `paths.dat` — but only when the container says
//! so: `meta.dat` bit 14 (`FLAG_HAS_LINE_COUNT_TABLE`) makes every record carry
//! its file's `line_count`. Without that bit the container states no sizes at
//! all and the only thing a reader can do is apply the writer's convention of
//! `DEFAULT_LINES_PER_FILE` addresses per file, which is what every line-only
//! trace written before the bit existed relies on.
//!
//! Reading it here rather than taking a caller's number keeps the eager and the
//! lazy step paths, the `linehits.tc` keys and the breakpoint resolution all
//! inverting through the SAME space, built from the same bytes.

use codetracer_trace_writer::line_position::LinePositionSpace;

use super::ctfs_container::CtfsReader;
use super::meta_dat::{FLAG_HAS_LINE_COUNT_TABLE, parse_meta_dat};

/// The `paths.off` record framing: `record_count + 1` little-endian `u64`
/// end-offsets, so the file count is one less than the number of entries.
const OFFSET_ENTRY_BYTES: u64 = 8;

/// How many source paths a container's interning table registers, or `None`
/// when it carries no `paths.off` at all (a legacy container that never wrote
/// the binary interning tables).
pub fn container_path_count(ctfs: &CtfsReader) -> Option<usize> {
    let size = ctfs.file_size("paths.off")?;
    let entries = size / OFFSET_ENTRY_BYTES;
    // A table with `n` records has `n + 1` offsets; anything smaller carries no
    // record at all.
    entries.checked_sub(1).map(|n| n as usize)
}

fn decode_varint(data: &[u8], pos: &mut usize) -> Option<u64> {
    let mut result: u64 = 0;
    let mut shift: u32 = 0;
    loop {
        let byte = *data.get(*pos)?;
        *pos += 1;
        result |= u64::from(byte & 0x7f) << shift;
        if byte & 0x80 == 0 {
            return Some(result);
        }
        shift += 7;
        if shift >= 64 {
            return None;
        }
    }
}

/// The per-file line counts a container RECORDS, or `None` when it records
/// none.
///
/// `None` is not "the files have no lines" — it is "this container states no
/// sizes", which is every trace without `meta.dat` bit 14. The distinction is
/// the point: a caller that cannot tell a recorded size from an assumed one is
/// back to the guess this table exists to remove.
///
/// A record that does not decode, or that states a count of zero, yields `None`
/// for the whole container rather than a partly-real table. A file sized zero
/// would share its base with the next file and the two would be
/// indistinguishable at decode; a table with one made-up entry shifts the base
/// of every file after it. Falling back to the uniform space is the honest
/// outcome — it is what the container would have meant with the bit clear —
/// and it is bounded, whereas a half-recovered table is not.
fn container_line_counts(ctfs: &mut CtfsReader, path_count: usize) -> Option<Vec<u64>> {
    let meta = ctfs.read_file("meta.dat").ok()?;
    let parsed = parse_meta_dat(&meta).ok()?;
    if parsed.flags & FLAG_HAS_LINE_COUNT_TABLE == 0 {
        return None;
    }

    let dat = ctfs.read_file("paths.dat").ok()?;
    let off = ctfs.read_file("paths.off").ok()?;
    if off.len() % 8 != 0 || off.len() / 8 < path_count + 1 {
        return None;
    }

    let end_at = |i: usize| -> u64 {
        let b = &off[i * 8..i * 8 + 8];
        u64::from_le_bytes([b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]])
    };

    let mut counts = Vec::with_capacity(path_count);
    for i in 0..path_count {
        let start = usize::try_from(end_at(i)).ok()?;
        let end = usize::try_from(end_at(i + 1)).ok()?;
        if start > end || end > dat.len() {
            return None;
        }
        let record = &dat[start..end];
        // `payload_len + payload + line_count` — the same framing as the
        // column-aware Layout A record, without its trailing per-line table.
        let mut pos = 0usize;
        let payload_len = usize::try_from(decode_varint(record, &mut pos)?).ok()?;
        pos = pos.checked_add(payload_len)?;
        if pos > record.len() {
            return None;
        }
        let count = decode_varint(record, &mut pos)?;
        if count == 0 || pos != record.len() {
            return None;
        }
        counts.push(count);
    }
    Some(counts)
}

/// The line-only address space of a container, built from its own path table.
///
/// `None` when the container registers no paths — there is then no space to
/// resolve into, and a caller must report an address as unplaceable rather than
/// invent a file for it.
pub fn container_line_space(ctfs: &mut CtfsReader) -> Option<LinePositionSpace> {
    let count = match container_path_count(ctfs) {
        Some(count) if count > 0 => count,
        _ => return None,
    };
    match container_line_counts(ctfs, count) {
        Some(counts) => Some(LinePositionSpace::from_line_counts(&counts)),
        None => Some(LinePositionSpace::uniform(count)),
    }
}
