//! The **active-altitude resolver** for mixed native + VM (GDScript) traces.
//!
//! Spec: `codetracer-specs/Planned-Features/Mixed-Trace-Implicit-Switch.md`.
//! This module is the span-driven, MCR-free half of the black-box
//! position-resolution's altitude computation (MT5): given the container's
//! crossing-span stream and the current moment (a step ordinal), it says which
//! altitude the debugger's attention belongs at — the VM (GDScript) or native.
//!
//! It has **no MCR / native-replay dependency**. Native-altitude *replay* needs
//! a real combined trace (MT14) and is out of scope here; this module only
//! decides the altitude from spans, exactly as spec §2 defines it.
//!
//! # The two altitudes (spec §1)
//!
//! A combined native+GDScript recording has two altitudes at any moment inside a
//! script call: **native** (present at every moment — the whole thing is a
//! native process) and the **VM** (GDScript), present *only* inside a **crossing
//! span** — a [`SpanRecord`] whose `[start_step, end_step]` bounds the
//! materialized steps of one VM frame.
//!
//! # Purity
//!
//! Every function here is pure over its inputs: a slice of the container's
//! (settled) span records, a step ordinal, and — for the override-aware
//! entry points — an [`AltitudeState`]. Nothing reads a replay session or the
//! filesystem.
//!
//! ## Why `&[SpanRecord]` rather than `&SpanStreamReader`
//!
//! The design brief named `&SpanStreamReader`, but that reader's read methods
//! take `&mut self` (they lazily decompress and cache chunks), which would make
//! every resolver call require a mutable borrow and defeat the point of a pure,
//! side-effect-free altitude function. Callers instead settle the spans once
//! (`reader.settled_spans()`), keep the resulting `Vec`, and pass a borrow of
//! it. This also decouples the resolver from the reader entirely, so its unit
//! tests can hand it plain hand-built `SpanRecord`s.

use crate::ctfs_trace_reader::span_stream::SpanRecord;

/// The active altitude at a moment (spec §1 — "the two altitudes").
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Altitude {
    /// The VM (GDScript) altitude — the highest live language, inside a crossing
    /// span. This is where P1 puts attention by default.
    Vm,
    /// The native (C++/engine) altitude — present at every moment, and the only
    /// altitude outside any crossing span.
    Native,
}

/// A deliberate-descent override (spec §2, §2.3, P3).
///
/// When the user deliberately switches down to native *inside* a VM crossing
/// span (the existing `openAlternativeView` gesture), that choice is pinned to
/// the span it was made in: it holds while execution stays within that span and
/// is released on leaving it. `override_span` holds the pinned span's id, or
/// `None` when no deliberate descent is in force.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AltitudeState {
    /// `span_id` of the crossing span a deliberate descent was scoped to, or
    /// `None`. Set by [`descend`], cleared by [`recompute_release`] once the
    /// moment leaves that span.
    pub override_span: Option<u64>,
}

/// Whether a span marks a VM crossing (spec §1) — the one place the predicate
/// lives.
///
/// A VM crossing span is the boundary of a script frame the user debugs in the
/// source language. GDScript frames are written with `span_type`
/// `"gdscript-frame"`; the general `"vm-crossing"` name is accepted too so a
/// second VM language can reuse this resolver without editing it. Non-VM spans
/// (`"web-request"`, `"process"`, `"test"`, …) are never crossings and are
/// ignored by every function below.
pub fn is_vm_crossing_span(span: &SpanRecord) -> bool {
    span.span_type.starts_with("gdscript") || span.span_type == "vm-crossing"
}

/// Whether `span` is a VM crossing whose covered step range includes `step`.
///
/// For a **closed** crossing the range is inclusive on both ends:
/// `start_step` is the first step inside the frame and `end_step` the last
/// (span_stream record model).
///
/// For an **open** crossing — the in-flight frame of a load-while-recording
/// session — `end_step` is `0` (not yet known). Per
/// `codetracer-trace-format-spec/nested-trace-correlation.md` §1.4 an open
/// crossing covers `[start_step, recording_head]`, the live edge. Every valid
/// query step is `<= recording_head` by construction (you cannot query past what
/// has been recorded), so an open crossing covers `step` iff `start_step <= step`
/// — there is no upper bound to test. The old `step <= end_step` test would be
/// false for any `step >= 1` against `end_step == 0`, wrongly resolving the live
/// frame the user is sitting in to native.
fn crossing_covers(span: &SpanRecord, step: u64) -> bool {
    if !is_vm_crossing_span(span) {
        return false;
    }
    if span.is_open {
        span.start_step <= step
    } else {
        span.start_step <= step && step <= span.end_step
    }
}

/// The effective inclusive upper bound of a crossing, for the innermost
/// tie-break.
///
/// A **closed** crossing bounds at its real `end_step`. An **open** crossing
/// (`codetracer-trace-format-spec/nested-trace-correlation.md` §1.4) covers to
/// the live edge, which is past every valid query step, so its effective end is
/// `u64::MAX`. This keeps the "tighter interval wins on a tie" rule correct in
/// both directions: a closed inner span (a real, smaller `end_step`) is tighter
/// than an enclosing open span, while a deeper span — open or not — still wins on
/// the primary `start_step` key before `end_step` is consulted.
fn effective_end_step(span: &SpanRecord) -> u64 {
    if span.is_open {
        u64::MAX
    } else {
        span.end_step
    }
}

/// The **innermost** VM crossing span covering `step`, or `None` when the moment
/// is in pure native (spec §2's `containingSpan`).
///
/// "Innermost" is the most deeply nested covering frame: with a `compute` frame
/// `[3, 6]` and a `scale` frame `[4, 5]` nested inside it, the innermost span at
/// step 5 is `scale`. We pick the covering span with the **largest
/// `start_step`**, breaking ties toward the **smallest `end_step`** — i.e. the
/// tightest enclosing interval, which for properly nested spans is the deepest
/// frame. The scan is linear over the settled spans, which is all the reader
/// offers and is ample: a container holds a handful of frames per moment.
pub fn innermost_crossing_span(spans: &[SpanRecord], step: u64) -> Option<SpanRecord> {
    spans
        .iter()
        .filter(|s| crossing_covers(s, step))
        .max_by(|a, b| {
            a.start_step
                .cmp(&b.start_step)
                // Larger start_step wins (deeper). On a tie, the smaller
                // effective end_step is the tighter interval, so reverse the
                // comparison to make it the maximum. `effective_end_step` maps an
                // open crossing to `u64::MAX` (§1.4) so a closed inner span is
                // correctly tighter than an enclosing open one. Both keys are
                // `u64::cmp`, so the ordering is total and consistent.
                .then_with(|| effective_end_step(b).cmp(&effective_end_step(a)))
        })
        .cloned()
}

/// Whether the override span (if any) still covers `step`.
///
/// The override is pinned by `span_id`; it stays in force only while the moment
/// is inside that exact span's `[start_step, end_step]`.
fn override_covers(state: &AltitudeState, spans: &[SpanRecord], step: u64) -> bool {
    match state.override_span {
        None => false,
        Some(id) => spans
            .iter()
            .any(|s| s.span_id == id && s.start_step <= step && step <= s.end_step),
    }
}

/// The active altitude at `step`, given a deliberate-descent `state` (spec §2).
///
/// Implements §2's rule verbatim:
///
/// ```text
/// if override is set and the new moment is still inside override.span:
///     A := native                     # P3: deliberate descent still in force
/// else:
///     A := gd if a covering crossing span exists else native   # P1
/// ```
///
/// This function is **read-only**: it never clears the override. Per §2 the
/// caller releases a stale override (via [`recompute_release`]) as a separate
/// step; keeping this query pure means asking "what altitude is it here?"
/// without mutating navigation state.
pub fn active_altitude(state: &AltitudeState, spans: &[SpanRecord], step: u64) -> Altitude {
    // P3 — a deliberate descent still covering this moment keeps us native.
    if override_covers(state, spans, step) {
        return Altitude::Native;
    }
    // P1 — attention belongs at the highest live altitude: VM inside a crossing
    // span, native otherwise.
    if innermost_crossing_span(spans, step).is_some() {
        Altitude::Vm
    } else {
        Altitude::Native
    }
}

/// Perform a **deliberate descent** at `step` (spec §2.3, P2/P3).
///
/// This is the `openAlternativeView` gesture: it scopes an override to the
/// innermost crossing span covering the current moment, so [`active_altitude`]
/// returns [`Altitude::Native`] while execution stays inside that frame. A
/// descent at a moment with no covering crossing span is a no-op (there is no VM
/// frame to descend *from*), which leaves the override clear.
pub fn descend(state: &mut AltitudeState, spans: &[SpanRecord], step: u64) {
    state.override_span = innermost_crossing_span(spans, step).map(|s| s.span_id);
}

/// Release the override if `step` has left the span it was pinned to (spec §2,
/// P3 — "released on leaving the span it was made in").
///
/// Call this after every navigation, before consulting [`active_altitude`], so
/// that stepping out of the deliberately-inspected frame lets P1 reassert: the
/// altitude rises back to the enclosing VM frame if one still covers the moment,
/// or to native if none does. Clearing an override that still covers the moment
/// would drop the deliberate descent early, so this only clears when the moment
/// is genuinely outside.
pub fn recompute_release(state: &mut AltitudeState, spans: &[SpanRecord], step: u64) {
    if state.override_span.is_some() && !override_covers(state, spans, step) {
        state.override_span = None;
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    /// A crossing span of the given frame range.
    fn gd_frame(span_id: u64, start_step: u64, end_step: u64) -> SpanRecord {
        SpanRecord {
            span_id,
            start_step,
            end_step,
            span_type: "gdscript-frame".to_string(),
            ..SpanRecord::default()
        }
    }

    /// An OPEN crossing span — the in-flight frame of a load-while-recording
    /// session. `is_open` is set and `end_step` is 0 (not yet known), matching
    /// what the recorder appends on entering a crossing
    /// (`nested-trace-correlation.md` §1.4).
    fn open_gd_frame(span_id: u64, start_step: u64) -> SpanRecord {
        SpanRecord {
            span_id,
            start_step,
            end_step: 0,
            is_open: true,
            span_type: "gdscript-frame".to_string(),
            ..SpanRecord::default()
        }
    }

    /// A non-VM span — must be invisible to every resolver function.
    fn web_span(span_id: u64, start_step: u64, end_step: u64) -> SpanRecord {
        SpanRecord {
            span_id,
            start_step,
            end_step,
            span_type: "web-request".to_string(),
            ..SpanRecord::default()
        }
    }

    #[test]
    fn non_vm_spans_are_not_crossings() {
        let spans = vec![web_span(1, 0, 100)];
        assert!(innermost_crossing_span(&spans, 5).is_none());
        assert_eq!(active_altitude(&AltitudeState::default(), &spans, 5), Altitude::Native);
    }

    #[test]
    fn innermost_wins_over_enclosing() {
        // compute [3,6] with scale [4,5] nested inside it.
        let spans = vec![gd_frame(1, 3, 6), gd_frame(2, 4, 5)];
        assert_eq!(innermost_crossing_span(&spans, 5).unwrap().span_id, 2);
        // At step 6 only the outer frame covers.
        assert_eq!(innermost_crossing_span(&spans, 6).unwrap().span_id, 1);
    }

    #[test]
    fn p1_altitude_follows_spans() {
        let spans = vec![gd_frame(1, 3, 6), gd_frame(2, 4, 5)];
        let s = AltitudeState::default();
        assert_eq!(active_altitude(&s, &spans, 1), Altitude::Native); // outside
        assert_eq!(active_altitude(&s, &spans, 5), Altitude::Vm); // inside
    }

    #[test]
    fn p3_descent_is_span_scoped() {
        let spans = vec![gd_frame(1, 3, 6), gd_frame(2, 4, 5)];
        let mut s = AltitudeState::default();

        // Descend at step 5 -> override pinned to the innermost (scale) span.
        descend(&mut s, &spans, 5);
        assert_eq!(s.override_span, Some(2));
        assert_eq!(active_altitude(&s, &spans, 5), Altitude::Native);

        // Move to step 6 — inside the OUTER frame but outside the override:
        // release fires, P1 gives VM for the enclosing compute frame.
        recompute_release(&mut s, &spans, 6);
        assert_eq!(s.override_span, None);
        assert_eq!(active_altitude(&s, &spans, 6), Altitude::Vm);

        // Descend again at 5, then leave every span at step 8: native by P1.
        descend(&mut s, &spans, 5);
        recompute_release(&mut s, &spans, 8);
        assert_eq!(s.override_span, None);
        assert_eq!(active_altitude(&s, &spans, 8), Altitude::Native);
    }

    #[test]
    fn open_crossing_covers_to_the_live_edge() {
        // The live frame started at step 4 and is still recording (end_step 0).
        let spans = vec![open_gd_frame(1, 4)];
        let s = AltitudeState::default();

        // Below start_step: native (the frame has not begun yet).
        assert!(innermost_crossing_span(&spans, 3).is_none());
        assert_eq!(active_altitude(&s, &spans, 3), Altitude::Native);

        // At and past start_step: VM, all the way to the live edge — the open
        // crossing has no upper bound (§1.4).
        for step in [4u64, 5, 100, u64::MAX] {
            assert_eq!(
                innermost_crossing_span(&spans, step).unwrap().span_id,
                1,
                "open crossing must cover step {step}"
            );
            assert_eq!(
                active_altitude(&s, &spans, step),
                Altitude::Vm,
                "open crossing => VM at step {step}"
            );
        }
    }

    #[test]
    fn closed_inner_is_tighter_than_open_outer() {
        // An open outer frame [4, live] with a CLOSED inner frame [6, 8] nested
        // inside it.
        let spans = vec![open_gd_frame(1, 4), gd_frame(2, 6, 8)];

        // Inside the inner frame the innermost is the closed inner (id 2): its
        // real end_step 8 is tighter than the open outer's effective u64::MAX.
        assert_eq!(innermost_crossing_span(&spans, 7).unwrap().span_id, 2);

        // In the outer-but-not-inner region (>= outer.start_step, past the inner)
        // only the open outer covers.
        assert_eq!(innermost_crossing_span(&spans, 9).unwrap().span_id, 1);
        // Between the outer's start and the inner's start, likewise the outer.
        assert_eq!(innermost_crossing_span(&spans, 5).unwrap().span_id, 1);
    }

    #[test]
    fn deeper_open_span_wins_by_start_step() {
        // Two open frames: an outer [4, live] and a deeper open inner [6, live].
        // The deeper one (larger start_step) must win on the primary key even
        // though both have the same effective end (u64::MAX).
        let spans = vec![open_gd_frame(1, 4), open_gd_frame(2, 6)];
        assert_eq!(innermost_crossing_span(&spans, 7).unwrap().span_id, 2);
        // Before the inner begins, the outer covers.
        assert_eq!(innermost_crossing_span(&spans, 5).unwrap().span_id, 1);
    }

    #[test]
    fn descend_outside_any_span_is_a_noop() {
        let spans = vec![gd_frame(1, 3, 6)];
        let mut s = AltitudeState::default();
        descend(&mut s, &spans, 1);
        assert_eq!(s.override_span, None);
    }
}
