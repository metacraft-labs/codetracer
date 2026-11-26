//! The resident per-step index `TraceReader::load_location` reads a function's
//! last line from when the source's own boundaries are unavailable, and the
//! step-read counter that bounds what computing that line costs.
//!
//! Kept out of `trace_reader.rs`, which holds only the `TraceReader` trait
//! (`tests/compact_profile_equivalence_test.rs` enumerates the trait's query
//! surface by reading that file).
//!
//! See [`CallRunLineIndex`] for why it exists: codetracer-pm
//! `issues/2026-11-26-large-evm-recordings-cannot-be-debugged-in-the-hydrated-debug-page.md`.

use codetracer_trace_types::{CallKey, NO_KEY, StepId};

use crate::trace_reader::TraceReader;

thread_local! {
    /// Steps read on this thread to find a function's last line in
    /// [`TraceReader::load_location`]: every step the fallback walk visits, and
    /// every step read to build a [`CallRunLineIndex`].
    static FUNCTION_LAST_STEP_READS: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}

/// The number of steps read on this thread to compute `function_last` in
/// [`TraceReader::load_location`].
///
/// An operation count rather than a timing, so a test can bound the cost of
/// `load_location` over a long call without depending on the host's speed.
/// Per thread because the walk runs on the caller's thread: a test reads its
/// own reads and nobody else's.
pub fn function_last_step_reads_on_this_thread() -> u64 {
    FUNCTION_LAST_STEP_READS.with(|count| count.get())
}

pub(crate) fn count_function_last_step_reads(n: u64) {
    FUNCTION_LAST_STEP_READS.with(|count| count.set(count.get().saturating_add(n)));
}

/// The greatest line over the run of `call_key` that begins at `start`, served
/// from the two M0/3 indices — `call_run_end` and `max_line_over_steps` — when
/// the reader has both.
///
/// `Some(None)` is an EMPTY run (the step at `start` does not carry
/// `call_key`), `Some(Some(line))` a run's greatest line, and `None` that the
/// reader lacks one of the indices. This is the default of
/// [`TraceReader::max_line_over_call_run`], and a free function so a reader
/// that overrides that method can still try it first.
pub fn max_line_over_call_run_from_line_map<R: TraceReader + ?Sized>(
    reader: &R,
    start: StepId,
    call_key: CallKey,
) -> Option<Option<i64>> {
    let end = reader.call_run_end(start, call_key)?;
    if end.0 <= start.0 {
        return Some(None);
    }
    reader.max_line_over_steps(start, end).map(Some)
}

/// A resident per-step index of the greatest line over the REST of each step's
/// call run: entry `i` is the maximum line over steps `i..` up to (not
/// including) the first step whose call key differs from step `i`'s.
///
/// It exists for readers that have neither M0/3 line index — a column-aware
/// trace has no `step-map.ns` — on which `load_location` otherwise finds a
/// function's last line by walking to the end of the call. A long single-call
/// trace (an EVM transaction is one call) made that O(n) per `load_location`
/// and O(n^2) per call flow.
///
/// Built in one backward pass over the steps, each read once; 8 bytes per step
/// resident (16 while it is built).
///
/// EXACTLY the walk's answer, including its treatment of a step id the reader
/// has no step for (an annotation hole on the lazy path): the walk `continue`s
/// past it, so a hole neither ends a run nor contributes a line, and the index
/// carries the run straight through it. A hole's own entry is [`Self::HOLE`]
/// and is never served: a query at a hole has no step to compare call keys
/// with and returns `None`, so the caller walks, as it always did.
#[derive(Debug, Clone)]
pub struct CallRunLineIndex {
    suffix_max_line: Vec<i64>,
}

impl CallRunLineIndex {
    /// The entry of a step id with no step. No recorded line is this small.
    pub const HOLE: i64 = i64::MIN;

    /// Build the index from each step's `(call_key, line)`, `None` for a step
    /// id with no step. `steps` yields the steps in order; ids it does not
    /// reach within `len` are holes.
    pub fn build(len: usize, steps: impl IntoIterator<Item = Option<(CallKey, i64)>>) -> Self {
        let mut lines = vec![Self::HOLE; len];
        let mut keys = vec![NO_KEY; len];
        let mut read = 0u64;
        for (i, step) in steps.into_iter().take(len).enumerate() {
            read += 1;
            if let Some((key, line)) = step {
                keys[i] = key;
                lines[i] = line;
            }
        }
        count_function_last_step_reads(read);
        Self::from_lines(lines, &keys)
    }

    /// Turn per-step lines (holes as [`Self::HOLE`]) into suffix maxima within
    /// each call run, in place. `keys[i]` is read only where `lines[i]` is not
    /// a hole. The caller accounts for the step reads that produced `lines`.
    pub fn from_lines(mut lines: Vec<i64>, keys: &[CallKey]) -> Self {
        // The (call key, suffix maximum) of the nearest PRESENT step after `i`.
        let mut next: Option<(CallKey, i64)> = None;
        for i in (0..lines.len()).rev() {
            let line = lines[i];
            if line == Self::HOLE {
                continue;
            }
            let key = keys.get(i).copied().unwrap_or(NO_KEY);
            let here = match next {
                Some((next_key, next_max)) if next_key == key => line.max(next_max),
                _ => line,
            };
            lines[i] = here;
            next = Some((key, here));
        }
        CallRunLineIndex { suffix_max_line: lines }
    }

    /// The number of step ids the index spans.
    pub fn len(&self) -> usize {
        self.suffix_max_line.len()
    }

    /// `true` when the index spans no steps.
    pub fn is_empty(&self) -> bool {
        self.suffix_max_line.is_empty()
    }

    /// The greatest line over the run of `call_key` beginning at `start`, with
    /// the meaning of [`TraceReader::max_line_over_call_run`].
    ///
    /// `None` when the index does not describe `reader` (a different step
    /// count) or `start` has no step: in both cases the caller walks.
    pub fn max_line_over_call_run<R: TraceReader + ?Sized>(
        &self,
        reader: &R,
        start: StepId,
        call_key: CallKey,
    ) -> Option<Option<i64>> {
        if self.suffix_max_line.len() != reader.step_count() {
            return None;
        }
        let index = usize::try_from(start.0).ok()?;
        let step = reader.step(start)?;
        if step.call_key != call_key {
            return Some(None);
        }
        match self.suffix_max_line.get(index).copied() {
            Some(Self::HOLE) | None => None,
            Some(line) => Some(Some(line)),
        }
    }
}

#[cfg(test)]
mod call_run_line_index_tests {
    use super::*;

    /// The walk `load_location` falls back to, over plain arrays: from
    /// `start`, skip holes, stop at the first present step of another key.
    fn walk(lines: &[i64], keys: &[CallKey], start: usize, key: CallKey) -> Option<i64> {
        let mut max = None;
        for i in start..lines.len() {
            if lines[i] == CallRunLineIndex::HOLE {
                continue;
            }
            if keys[i] != key {
                break;
            }
            max = Some(max.map_or(lines[i], |m: i64| m.max(lines[i])));
        }
        max
    }

    /// Every present step's entry is the walk's maximum over its own run,
    /// across run boundaries, a key that recurs after another run (two runs,
    /// not one), and holes, which neither end a run nor contribute a line.
    #[test]
    fn suffix_maxima_equal_the_walk_including_across_holes() {
        let h = CallRunLineIndex::HOLE;
        let k = |n: i64| CallKey(n);
        let lines = vec![5, 9, h, 3, 7, h, 2, 8, 1, h, h, 4];
        let keys = vec![k(0), k(0), k(9), k(0), k(1), k(1), k(1), k(0), k(0), k(5), k(0), k(-1)];
        let index = CallRunLineIndex::from_lines(lines.clone(), &keys);
        assert_eq!(index.len(), lines.len());
        for i in 0..lines.len() {
            if lines[i] == h {
                assert_eq!(index.suffix_max_line[i], h, "a hole stays a hole at {i}");
                continue;
            }
            assert_eq!(
                Some(index.suffix_max_line[i]),
                walk(&lines, &keys, i, keys[i]),
                "suffix maximum at step {i}"
            );
        }
        // The run of key 0 starting at 0 runs through the hole at 2 to 3; the
        // later key-0 run (7..) is a different run.
        assert_eq!(index.suffix_max_line[0], 9);
        assert_eq!(index.suffix_max_line[7], 8);
        // Through two holes in a row.
        assert_eq!(index.suffix_max_line[8], 1);
    }

    #[test]
    fn an_empty_index_is_empty() {
        let index = CallRunLineIndex::from_lines(vec![], &[]);
        assert!(index.is_empty());
        let built = CallRunLineIndex::build(3, vec![Some((CallKey(0), 4)), None]);
        // The iterator stopped early: the missing tail is holes.
        assert_eq!(
            built.suffix_max_line,
            vec![4, CallRunLineIndex::HOLE, CallRunLineIndex::HOLE]
        );
    }
}
