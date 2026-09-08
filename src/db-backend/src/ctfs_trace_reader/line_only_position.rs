//! Inverting a line-only `global_position_index`.
//!
//! A pre-extension container addresses a step with one integer that
//! "addresses one line" (`codetracer-trace-format-spec/trace-events.md`
//! §"Back-Compatibility"). The spec says nothing about how those integers are
//! apportioned between files, and the container records nothing about it: no
//! stride, no per-file line count, no producer identifier. Inverting one is
//! therefore an assumption about the writer, and two writers of this format
//! make different ones:
//!
//! * the Rust [`codetracer_trace_writer`] packs `(path_id << 32) | line`
//!   ([`codetracer_trace_writer::step_stream::pack_global_line_index`]);
//! * the Nim `codetracer_trace_format_nim` packs `prefix_sum[path_id] + line`
//!   with [`DEFAULT_LINES_PER_FILE`] addresses per file
//!   (`multi_stream_writer.nim` `toGlobalLineIndex`; ported for the *encode*
//!   direction as [`codetracer_trace_writer::column_aware::PositionSpace`],
//!   whose module header records that the divergence is deliberate and
//!   unrepaired).
//!
//! Both writers' containers reach `CTFSTraceReader::open_new_format_nim`, so a
//! reader that applies one packing unconditionally is wrong about the other's
//! traces. Applying `(path_id << 32) | line` to a Nim-written trace reports
//! `path_id = 0` and `line = path_id * 100_000 + line` for every step outside
//! path 0 — a location the debugger will happily show, and a breakpoint key
//! nothing ever matches.
//!
//! # What makes a decision possible without a discriminator
//!
//! The prefix-sum space is *falsifiable* and the shifted one is not. A
//! container registers a known number of paths, so the prefix-sum space has a
//! top — `path_count * DEFAULT_LINES_PER_FILE` for a line-only trace — and an
//! index at or above it cannot have come from that space. The shifted packing
//! puts every step outside path 0 at least `2^32` up, far past that top, so a
//! shift-packed trace announces itself. The reverse does not hold: every
//! prefix-sum index is *also* a well-formed shifted index for path 0.
//!
//! [`LineOnlyPositionSpace::resolve`] therefore reads an index as prefix-sum
//! when the space can hold it, as shifted when the space cannot and the
//! resulting path id exists in the trace, and refuses by name when neither
//! fits.
//!
//! # The one reading this cannot establish
//!
//! An index in `[DEFAULT_LINES_PER_FILE, top)` is well-formed under both: it
//! is `(path >= 1, line)` under prefix-sum and `(path 0, line >= 100_000)`
//! under shifted. Resolving it prefix-sum is a choice, and the trace it is
//! wrong about is a shift-packed one whose *first* registered file has more
//! than a hundred thousand lines. Nothing in the container separates the two
//! cases; separating them needs a discriminator at the format level, which is
//! where this divergence belongs.

use codetracer_trace_writer::column_aware::DEFAULT_LINES_PER_FILE;
use codetracer_trace_writer::step_stream::unpack_global_line_index;

/// The address space a container's line-only `global_position_index` values
/// were encoded in, as the Nim writer lays it out: one contiguous slot per
/// registered path, sized by that path's per-line length table when it has one
/// and [`DEFAULT_LINES_PER_FILE`] when it does not.
///
/// Built once per opened container and shared by every path that decodes a
/// step's coordinate, so those paths cannot answer differently.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LineOnlyPositionSpace {
    /// `prefix_sum[i]` is the first address of path `i`; the last element is
    /// the top of the space. Length is `path_count + 1`.
    prefix_sum: Vec<u64>,
}

impl LineOnlyPositionSpace {
    /// The space of a trace with `path_count` registered paths and no per-line
    /// length tables — every line-only container, and the only shape the lazy
    /// step path ever sees (a column-aware container is excluded from it and
    /// decodes through `GlobalPositionDecoder` instead).
    pub fn uniform(path_count: u64) -> Self {
        Self::from_line_lengths(&vec![Vec::new(); path_count as usize])
    }

    /// The space of a trace whose paths have the given per-line length tables,
    /// in registration order. An empty table means the writer was not given
    /// line lengths for that path, which is the mixed case: that path gets a
    /// `DEFAULT_LINES_PER_FILE` slot, exactly as the writer gives it one, so
    /// the paths after it keep their bases.
    pub fn from_line_lengths(per_file: &[Vec<u32>]) -> Self {
        let mut prefix_sum = Vec::with_capacity(per_file.len() + 1);
        let mut running: u64 = 0;
        prefix_sum.push(0);
        for lengths in per_file {
            let size = if lengths.is_empty() {
                DEFAULT_LINES_PER_FILE
            } else {
                lengths.iter().map(|l| u64::from(*l)).sum::<u64>().max(1)
            };
            running += size;
            prefix_sum.push(running);
        }
        Self { prefix_sum }
    }

    /// Number of paths this space covers.
    pub fn path_count(&self) -> u64 {
        (self.prefix_sum.len() - 1) as u64
    }

    /// One past the highest address the prefix-sum packing can produce.
    pub fn top(&self) -> u64 {
        *self.prefix_sum.last().unwrap_or(&0)
    }

    /// Resolve a line-only `global_position_index` to `(path_id, line)`, or say
    /// why it cannot be resolved.
    ///
    /// See the module header for which packing is applied when, and for the one
    /// index range in which the choice is not established by evidence.
    pub fn resolve(&self, gli: u64) -> Result<(u64, u64), String> {
        let path_count = self.path_count();
        if path_count == 0 {
            return Err(format!(
                "line-only global_position_index {gli} cannot be resolved to (path, line): \
                 the trace registers no paths"
            ));
        }

        if gli < self.top() {
            // Largest i with prefix_sum[i] <= gli. `prefix_sum[0] == 0 <= gli`
            // and `gli < prefix_sum[path_count]`, so the answer is in range.
            let idx = self.prefix_sum.partition_point(|base| *base <= gli) - 1;
            return Ok((idx as u64, gli - self.prefix_sum[idx]));
        }

        // Above the prefix-sum space, so not that packing. The shifted packing
        // is the other one in circulation; take it only if the path id it
        // yields is one this trace actually registered.
        let (shifted_path, shifted_line) = unpack_global_line_index(gli);
        if (shifted_path as u64) < path_count {
            return Ok((shifted_path as u64, shifted_line as u64));
        }

        Err(format!(
            "line-only global_position_index {gli} is outside this trace's \
             prefix-sum address space of {} ({} path(s)), and reading it as the \
             other packing in circulation — (path_id << 32) | line, \
             codetracer_trace_writer step_stream.rs pack_global_line_index — \
             gives path {shifted_path}, which this trace does not register. A \
             line-only container records no packing discriminator, so there is \
             nothing further to try",
            self.top(),
            path_count
        ))
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::panic, clippy::expect_used)]
mod tests {
    use super::*;
    use codetracer_trace_writer::column_aware::PositionSpace;
    use codetracer_trace_writer::step_stream::pack_global_line_index;

    /// The encode side of the Nim packing, taken from the crate's own port
    /// rather than reimplemented, so this test fails if the two drift.
    fn nim_pack(path_count: usize, path_id: u64, line: u64) -> u64 {
        let mut space = PositionSpace::new(false);
        for _ in 0..path_count {
            space.push_path(&[]);
        }
        space.position_of(path_id, line)
    }

    /// Every address the Nim writer produces inverts to the `(path, line)` it
    /// was produced from. This is the half that was broken: applied to a
    /// two-path trace, `unpack_global_line_index` answers (0, 100007) for the
    /// step recorded at (1, 7).
    #[test]
    fn prefix_sum_addresses_resolve_to_what_was_recorded() {
        let space = LineOnlyPositionSpace::uniform(3);
        assert_eq!(space.top(), 3 * DEFAULT_LINES_PER_FILE);

        for &(path, line) in &[(0u64, 1u64), (0, 7), (1, 7), (1, 99_999), (2, 42)] {
            let gli = nim_pack(3, path, line);
            assert_eq!(
                space.resolve(gli),
                Ok((path, line)),
                "gli {gli} was written for (path {path}, line {line})"
            );
        }

        // The concrete pair from the report, spelled out.
        assert_eq!(nim_pack(3, 1, 7), 100_007);
        assert_eq!(space.resolve(100_007), Ok((1, 7)));
        assert_eq!(
            unpack_global_line_index(100_007),
            (0, 100_007),
            "the shifted inverse is what used to answer here"
        );
    }

    /// A container from the Rust writer announces itself: every step outside
    /// path 0 is at least 2^32 up, past the top of the prefix-sum space, and is
    /// read with the packing that produced it.
    #[test]
    fn shifted_addresses_above_the_space_resolve_under_their_own_packing() {
        let space = LineOnlyPositionSpace::uniform(2);
        assert_eq!(space.top(), 200_000);

        let gli = pack_global_line_index(1, 5);
        assert_eq!(gli, 4_294_967_301);
        assert_eq!(space.resolve(gli), Ok((1, 5)));

        // Path 0 coincides under both packings, so it needs no disambiguation.
        assert_eq!(space.resolve(pack_global_line_index(0, 5)), Ok((0, 5)));
    }

    /// An index that neither packing can place in this trace is refused, with
    /// the index, the space and the rival packing named.
    #[test]
    fn an_index_neither_packing_places_is_refused_by_name() {
        let space = LineOnlyPositionSpace::uniform(2);
        let gli = pack_global_line_index(9, 3);

        let err = space.resolve(gli).expect_err("path 9 is not registered");
        assert!(err.contains(&gli.to_string()), "must name the index: {err}");
        assert!(err.contains("200000"), "must name the space: {err}");
        assert!(
            err.contains("pack_global_line_index"),
            "must name the rival packing: {err}"
        );
    }

    /// A trace with no registered paths has no space to resolve into, and says
    /// so instead of indexing an empty prefix sum.
    #[test]
    fn a_pathless_trace_is_refused_not_defaulted() {
        let space = LineOnlyPositionSpace::uniform(0);
        let err = space.resolve(0).expect_err("no paths, nothing to resolve into");
        assert!(err.contains("registers no paths"), "{err}");
    }

    /// The mixed column-aware case: a path with a line-length table occupies
    /// its byte capacity, one without occupies `DEFAULT_LINES_PER_FILE`, and
    /// the base of the path after them is the sum. Sizing an untabled path 0
    /// would put every later path's base at the wrong address.
    #[test]
    fn mixed_line_length_tables_size_each_path_as_the_writer_does() {
        let space = LineOnlyPositionSpace::from_line_lengths(&[vec![10, 10], Vec::new(), vec![4]]);
        assert_eq!(space.top(), 20 + DEFAULT_LINES_PER_FILE + 4);
        assert_eq!(space.resolve(21), Ok((1, 1)));
        assert_eq!(space.resolve(20 + DEFAULT_LINES_PER_FILE), Ok((2, 0)));
    }
}
