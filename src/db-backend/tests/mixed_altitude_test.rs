//! Integration test for the span-driven active-altitude resolver
//! (`db_backend::mixed_altitude`) against a real committed `.ct` container.
//!
//! Spec: `codetracer-specs/Planned-Features/Mixed-Trace-Implicit-Switch.md`
//! (principles P1 / P3, the §2 behavior table, the §3 test expectations).
//!
//! # No mocks
//!
//! It opens the committed `tests/fixtures/gdscript_mixed/combined_trace.ct`
//! through the production `CtfsReader::open` + `SpanStreamReader::open_from_ctfs`
//! path — the same reader stack `span_stream_request_spans_test.rs` uses — and
//! reads the real crossing spans the canonical Nim writer wrote. The container
//! is generator-produced (see the fixture's `README.md` / `regenerate.sh`) and
//! COMMITTED, so this test always runs; a missing fixture fails loudly rather
//! than silently skipping.
//!
//! # Scope — the span-driven, MCR-free slice
//!
//! The fixture carries a materialized GDScript program plus crossing spans, and
//! **no** native `tNNN` streams / MCR replay. That is the slice the altitude
//! resolver needs (spec §2 computes the altitude from spans alone). The
//! native-altitude REPLAY expectations (T-DAP-1/4/5/6) need a real combined
//! native+GDScript trace from the MT14 substrate and are encoded as `#[ignore]`
//! stubs at the bottom of this file so the remaining §3 work stays greppable.

use std::path::PathBuf;

use db_backend::ctfs_trace_reader::ctfs_container::CtfsReader;
use db_backend::ctfs_trace_reader::span_stream::{SpanRecord, SpanStreamReader};
use db_backend::mixed_altitude::{
    active_altitude, descend, innermost_crossing_span, is_vm_crossing_span, recompute_release, Altitude, AltitudeState,
};

// ── Fixture plumbing ──────────────────────────────────────────────────────

fn fixture_ct() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("gdscript_mixed")
        .join("combined_trace.ct")
}

/// Open the committed container and return its settled span records.
fn load_spans() -> Vec<SpanRecord> {
    let ct = fixture_ct();
    assert!(
        ct.is_file(),
        "mixed-trace fixture missing at {} — this test must NOT silently skip",
        ct.display()
    );
    let mut ctfs = CtfsReader::open(&ct).unwrap_or_else(|e| panic!("CTFS open failed for {}: {}", ct.display(), e));
    let mut reader = SpanStreamReader::open_from_ctfs(&mut ctfs)
        .expect("span stream read")
        .expect("fixture declares a span stream (meta.dat bit 13)");
    reader.settled_spans().expect("settled spans")
}

/// The crossing spans only — the input the altitude resolver actually consumes.
fn crossing_spans() -> Vec<SpanRecord> {
    load_spans().into_iter().filter(is_vm_crossing_span).collect()
}

// ── Fixture-integrity guard (spec §3 / origin_gdscript_dap_test.rs:437) ─────

#[test]
fn test_mixed_fixture_is_present_and_has_two_crossing_spans() {
    let ct = fixture_ct();
    assert!(
        ct.is_file(),
        "mixed-trace fixture missing under {} — see the fixture README",
        ct.display()
    );
    let crossing = crossing_spans();
    assert_eq!(
        crossing.len(),
        2,
        "fixture must carry exactly the compute [3,6] and scale [4,5] crossing spans, got {crossing:?}"
    );
    // The exact frame ranges the assertions below depend on.
    let compute = crossing.iter().find(|s| s.span_id == 1).expect("compute span (id 1)");
    let scale = crossing.iter().find(|s| s.span_id == 2).expect("scale span (id 2)");
    assert_eq!((compute.start_step, compute.end_step), (3, 6), "compute frame range");
    assert_eq!((scale.start_step, scale.end_step), (4, 5), "scale frame range");
}

// ── P1: the active altitude follows execution (spec §2, §3.1 T-DAP-1) ───────

#[test]
fn test_step_outside_any_crossing_span_is_native() {
    // Step 1 is in the outer `_ready` body, before the compute frame [3,6].
    let spans = crossing_spans();
    assert_eq!(
        active_altitude(&AltitudeState::default(), &spans, 1),
        Altitude::Native,
        "P1: no covering crossing span => native"
    );
}

#[test]
fn test_step_inside_crossing_span_is_vm() {
    // Step 5 is inside both the compute [3,6] and scale [4,5] frames.
    let spans = crossing_spans();
    assert_eq!(
        active_altitude(&AltitudeState::default(), &spans, 5),
        Altitude::Vm,
        "P1: a covering crossing span => VM (GDScript)"
    );
}

#[test]
fn test_innermost_covering_span_is_chosen() {
    let spans = crossing_spans();
    // At step 5 both frames cover; the innermost is `scale` (span id 2).
    assert_eq!(
        innermost_crossing_span(&spans, 5).expect("a covering span at step 5").span_id,
        2,
        "innermost-wins: the deepest (scale) frame is chosen at step 5"
    );
    // At step 6 only `compute` (span id 1) covers.
    assert_eq!(
        innermost_crossing_span(&spans, 6).expect("a covering span at step 6").span_id,
        1,
        "at step 6 only the enclosing compute frame covers"
    );
}

// ── P3: a deliberate descent is span-scoped and releases on leaving ─────────

#[test]
fn test_deliberate_descent_is_span_scoped_and_releases() {
    let spans = crossing_spans();
    let mut state = AltitudeState::default();

    // Descend at step 5: the override pins to the innermost (scale) span, and
    // the altitude drops to native there (P3, the openAlternativeView gesture).
    descend(&mut state, &spans, 5);
    assert_eq!(state.override_span, Some(2), "descent pins the innermost span id");
    assert_eq!(
        active_altitude(&state, &spans, 5),
        Altitude::Native,
        "P3: deliberate descent => native inside the pinned span"
    );

    // Step to 6 — still inside the OUTER compute frame but outside the scale
    // override. recompute_release clears the override; P1 reasserts and the
    // altitude rises back to VM for the enclosing compute frame.
    recompute_release(&mut state, &spans, 6);
    assert_eq!(state.override_span, None, "P3: override released on leaving the pinned span");
    assert_eq!(
        active_altitude(&state, &spans, 6),
        Altitude::Vm,
        "P1 reasserts: VM for the still-covering compute frame"
    );

    // Descend again at 5, then leave every span at step 8 (back in outer
    // `_ready`, past the compute frame): override clears and P1 gives native.
    descend(&mut state, &spans, 5);
    assert_eq!(state.override_span, Some(2));
    recompute_release(&mut state, &spans, 8);
    assert_eq!(state.override_span, None, "override released past the outermost frame");
    assert_eq!(
        active_altitude(&state, &spans, 8),
        Altitude::Native,
        "P1: outside every crossing span => native"
    );
}

// ───────────────────────────────────────────────────────────────────────────
// Gated expectations (spec §3.1) — placeholders, NOT fake passes.
//
// These name the remaining §3 DAP-level expectations that need the MT14
// substrate (a real combined native+GDScript trace recorded by patched Godot
// under `ct-mcr` on Linux) and MCR native replay. They are `#[ignore]`d so
// `cargo test` lists them as ignored and they stay greppable; each body records
// the expectation and calls `unimplemented!` so it can never masquerade as
// green.
// ───────────────────────────────────────────────────────────────────────────

#[test]
#[ignore = "gated on MT14 real combined native+GDScript trace / MCR native replay"]
fn t_dap_1_default_view_follows_execution() {
    // From a native stop, `continue` to a breakpoint on a `.gd` line asserts
    // the stop's location.path is res://*.gd and its lang is Lang::GDScript
    // (A rose to gd, P1) — with no explicit select-replay issued by the test.
    unimplemented!("T-DAP-1: needs a combined native+GDScript trace (MT14) and the DAP handler mixed session");
}

#[test]
#[ignore = "gated on MT14 real combined native+GDScript trace / MCR native replay"]
fn t_dap_4_step_out_of_outermost_gd_frame_switches_to_native() {
    // `stepOut` from the top `.gd` frame lands at a native location.path with
    // native lang (P1 forced down); the mixed session's active backing swapped
    // to the native replay.
    unimplemented!("T-DAP-4: needs MCR native replay to land the native position after step-out (MT14)");
}

#[test]
#[ignore = "gated on MT14 real combined native+GDScript trace / MCR native replay"]
fn t_dap_5_explicit_switch_is_span_scoped() {
    // `ct/select-replay` to native inside a GD span lands the correlated native
    // position (same rrTicks, P5); a subsequent gd-level `stepOut` past the span
    // clears the override and the next stop is gd again (P3). The altitude-state
    // half is covered green above; this stub is the real session-swap over MCR.
    unimplemented!("T-DAP-5: needs a real session swap (ct/select-replay) over the MCR native backing (MT14)");
}

#[test]
#[ignore = "gated on MT14 real combined native+GDScript trace / MCR native replay"]
fn t_dap_6_correlation_both_directions_is_local() {
    // native pos -> covering span -> the GD step whose registerStep is current;
    // GD step -> seek native to that step's registerStep — asserting no global
    // correlation table is consulted (MT5).
    unimplemented!("T-DAP-6: needs both altitudes present (native tNNN streams + MCR replay) to correlate (MT14)");
}
