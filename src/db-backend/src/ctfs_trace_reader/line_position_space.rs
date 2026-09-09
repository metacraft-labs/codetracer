//! Building a container's LINE-ONLY address space from the container itself.
//!
//! A line-only `.ct` addresses each step with one integer that names one source
//! line. Which `(path_id, line)` it names is the spec's prefix sum over the
//! registered files in file-id order
//! (`codetracer-trace-format-spec/trace-events.md` §"Source Location
//! Addressing"), so inverting one needs the container's file count and nothing
//! else — which the container carries in `paths.off`, the offset index of its
//! path interning table.
//!
//! Reading it here rather than taking a caller's number keeps the eager and the
//! lazy step paths, the `linehits.tc` keys and the breakpoint resolution all
//! inverting through the SAME space, built from the same bytes.

use codetracer_trace_writer::line_position::LinePositionSpace;

use super::ctfs_container::CtfsReader;

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

/// The line-only address space of a container, built from its own path table.
///
/// `None` when the container registers no paths — there is then no space to
/// resolve into, and a caller must report an address as unplaceable rather than
/// invent a file for it.
pub fn container_line_space(ctfs: &CtfsReader) -> Option<LinePositionSpace> {
    match container_path_count(ctfs) {
        Some(count) if count > 0 => Some(LinePositionSpace::uniform(count)),
        _ => None,
    }
}
