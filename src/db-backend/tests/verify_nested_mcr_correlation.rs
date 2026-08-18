//! Nested-trace MCR ↔ GDScript correlation integration test — GDScript-Recorder
//! milestone **N2** (`e2e_nested_mcr_plus_gdscript_trace_correlated`, correlation
//! logic slice).
//!
//! Proves the db-backend correlates a materialized GDScript `.ct` (recorded by
//! the patched Godot engine, `metacraft-labs/codetracer-engine-godot`, branch
//! `codetracer/gdscript-recorder`) to its parent native MCR trace's `geid.idx`,
//! **both directions**, per the wire contract
//! `codetracer-trace-format-spec/nested-trace-correlation.md` §3:
//!
//! * **nested → native** (§3.1): a GDScript step → the native event/checkpoint
//!   that produced it.
//! * **native → nested** (§3.2): a native GEID → the GDScript step it came from
//!   (greatest join with `geid ≤ g'`).
//!
//! # What is REAL vs. what is the disclosed fixture
//!
//! * **REAL**: the GDScript `.ct` is a genuine recording of
//!   `test-programs/gdscript/n1_nested.gd` by the patched engine, run under the
//!   `CT_MCR_GEID`/`CT_MCR_TICK` shim (the controllable stand-in for the live
//!   `ct-mcr` context interface). Its `ct-nested-join:` events are read back
//!   through the **production** `CTFSTraceReader::open` +
//!   `MaterializedReplaySession` + `nested_correlation` code paths. No mock of
//!   the recorder, the reader, or the session.
//! * **DISCLOSED FIXTURE (justified)**: the parent native `geid.idx`
//!   (`native_geid.idx`) is a committed fixture in the **real** legacy `GIDX`
//!   wire format (`codetracer-native-recorder/.../geid_index.nim`). It stands in
//!   for the native MCR trace that a real `ct-mcr record` of the patched Godot
//!   would produce — which needs N2's Linux constellation (patched Godot built
//!   for Linux, `ct_cli record` on the Xvfb + Mesa lavapipe substrate). Mirrors
//!   how `src/db-backend/src/cross_process_origin.rs` tests cross-process origin
//!   against a synthetic `PairIndex` rather than spinning up a second real
//!   recording. Swapping this fixture for a real `geid.idx` is the only change
//!   the gated Linux e2e requires (see the N2 runbook in
//!   `GDScript-Recorder.milestones.org`).
//!
//! # No silent skip
//!
//! The `.ct` and `native_geid.idx` are committed, so the test always runs; a
//! missing fixture FAILS loudly (a repository-integrity error, not an
//! environment gap). Exits nonzero on any correlation mismatch. A tamper case
//! (a native index that does not cover the join GEIDs) proves the PASS is not
//! vacuous.

use std::path::PathBuf;
use std::sync::Arc;

use codetracer_trace_types::StepId;
use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::db::MaterializedReplaySession;
use db_backend::nested_correlation::{JoinSite, NativeGeidIndex};
use db_backend::trace_reader::TraceReader;

fn fixture_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("gdscript")
        .join("n2_nested")
}

fn open_reader() -> Arc<dyn TraceReader> {
    let dir = fixture_dir();
    let ct = dir.join("gdscript_trace.ct");
    assert!(
        ct.is_file(),
        "N2 GDScript fixture trace missing at {} — record it with the patched engine under the \
         CT_MCR shim (CT_MCR_GEID=1000 CT_MCR_TICK=500000; scripts/record-and-verify-n1.sh in the \
         codetracer-engine-godot fork produces the same join events); this test must NOT silently skip",
        ct.display()
    );
    Arc::new(CTFSTraceReader::open(&ct).unwrap_or_else(|e| panic!("CTFS open failed for {}: {}", ct.display(), e)))
}

fn native_index() -> NativeGeidIndex {
    let path = fixture_dir().join("native_geid.idx");
    assert!(
        path.is_file(),
        "N2 native geid.idx fixture missing at {} — the disclosed parent-native trace stand-in \
         (legacy GIDX format); this test must NOT silently skip",
        path.display()
    );
    NativeGeidIndex::from_file(&path).unwrap_or_else(|e| panic!("native geid.idx decode failed: {e}"))
}

/// (1) The recording carries the expected join events, and BOTH resolution
/// directions correlate a native frame ↔ the GDScript step with specific ids.
#[test]
fn verify_nested_mcr_correlation_both_directions() {
    let reader = open_reader();
    let session = MaterializedReplaySession::new(Arc::clone(&reader));
    let native = native_index();
    let corr = session.nested_correlation(native);

    // Diagnostic dump (always printed).
    for j in corr.joins() {
        eprintln!(
            "[N2 join] geid={} tick={} step={} site={:?} thread={}",
            j.geid, j.tick, j.step_id.0, j.site, j.thread
        );
    }

    // The real n1_nested.gd recording under CT_MCR_GEID=1000 emits 9 join events
    // at contiguous GEIDs 1000..=1008 (call-enter, native-calls, call-exits).
    let joins = corr.joins();
    assert_eq!(joins.len(), 9, "expected 9 join events from n1_nested.gd under the CT_MCR shim");
    assert!(!corr.is_unnested(), "a recording under the MCR shim is a NESTED trace");
    // GEID-monotonic in emission order (§3.3 — what makes the native->nested search valid).
    for w in joins.windows(2) {
        assert!(w[1].geid >= w[0].geid, "join GEIDs must be non-decreasing in emission order");
    }
    // All three sites present.
    assert!(joins.iter().any(|j| j.site == JoinSite::CallEnter), "a call-enter join");
    assert!(joins.iter().any(|j| j.site == JoinSite::NativeCall), "a native-call join");
    assert!(joins.iter().any(|j| j.site == JoinSite::CallExit), "a call-exit join");

    // ---- nested -> native (§3.1): a GDScript step -> the native checkpoint ----
    // step 1 is the call-enter join (geid 1000 -> native checkpoint 10).
    let r1 = corr.native_for_step(StepId(1)).expect("step 1 (call-enter) resolves to a native frame");
    assert_eq!(r1.native_geid, 1000, "step 1 join carries native GEID 1000");
    assert!(r1.exact, "GEID 1000 is an exact native geid.idx hit");
    assert_eq!(r1.checkpoint_id, 10, "native GEID 1000 -> checkpoint 10");
    // step 3 is a native-call join (geid 1001 -> native checkpoint 11) — the
    // load-bearing crossing where the native trace IS the continuation.
    let r3 = corr.native_for_step(StepId(3)).expect("step 3 (native-call) resolves to a native frame");
    assert_eq!(r3.native_geid, 1001, "step 3 native-call carries native GEID 1001");
    assert_eq!(r3.checkpoint_id, 11, "native GEID 1001 -> checkpoint 11");
    assert!(r3.exact);

    // ---- native -> nested (§3.2): a native GEID -> the GDScript step ----
    // Exact: native GEID 1003 -> the native-call join at step 5.
    let g1003 = corr.step_for_native_geid(1003).expect("native GEID 1003 resolves to a GDScript step");
    assert_eq!(g1003.step_id, StepId(5), "native GEID 1003 -> GDScript step 5");
    assert_eq!(g1003.site, JoinSite::NativeCall, "and it is the native-call crossing");
    // Exact: native GEID 1006 -> the call-exit join at step 7.
    let g1006 = corr.step_for_native_geid(1006).expect("native GEID 1006 resolves");
    assert_eq!(g1006.step_id, StepId(7), "native GEID 1006 -> GDScript step 7");
    // <= rule: native frame at GEID 1010 (a native-only checkpoint, no GDScript
    // join) resolves to the greatest join <= 1010 == the last join (geid 1008,
    // step 8). Proves the graceful-degradation binary search, not just exact hits.
    let g1010 = corr.step_for_native_geid(1010).expect("native GEID 1010 resolves via the <= rule");
    assert_eq!(g1010.geid, 1008, "native GEID 1010 -> greatest join GEID <= 1010 == 1008");
    assert_eq!(g1010.step_id, StepId(8), "which is GDScript step 8");
    // A native GEID before every recorded join is unresolvable (no fabrication).
    assert!(corr.step_for_native_geid(500).is_none(), "a native GEID below every join is unresolvable");

    // ROUND-TRIP: nested->native(step 3)==1001, and native->nested(1001) lands
    // back on step 3 (the same native-call crossing) — the two directions agree.
    let back = corr.step_for_native_geid(r3.native_geid).expect("1001 resolves back");
    assert_eq!(back.step_id, StepId(3), "native->nested(1001) round-trips to step 3");

    eprintln!(
        "[N2 correlation] 9 joins GEID 1000..1008; nested->native step3->geid1001->cp11; \
         native->nested 1003->step5, 1010(<=)->step8; round-trip step3<->geid1001 OK"
    );
}

/// (2) NON-VACUITY — a native index that does NOT cover the join GEIDs breaks
/// the correlation. Proves the PASS above genuinely depends on the native
/// `geid.idx` matching the recorded join keys, not on the resolver always
/// returning something.
#[test]
fn verify_nested_mcr_correlation_tamper_wrong_native_index() {
    let reader = open_reader();
    let session = MaterializedReplaySession::new(Arc::clone(&reader));

    // Baseline: the real native index resolves step 3.
    let ok = session.nested_correlation(native_index());
    assert!(ok.native_for_step(StepId(3)).is_some(), "baseline: step 3 resolves with the real index");

    // Tamper: a native index whose GEIDs are ALL far above the join GEIDs
    // (9000..9010) — every join's `nearest_at_or_before` misses, so no GDScript
    // step resolves to a native frame.
    let tampered_bytes = {
        let mut out = Vec::new();
        out.extend_from_slice(b"GIDX");
        out.extend_from_slice(&11u32.to_le_bytes());
        for i in 0..11u64 {
            out.extend_from_slice(&(9000 + i).to_le_bytes()); // geid far above 1008
            out.extend_from_slice(&(10 + i as u32).to_le_bytes()); // checkpoint
            out.extend_from_slice(&1u32.to_le_bytes()); // one thread tick
            out.extend_from_slice(&1u32.to_le_bytes()); // tid
            out.extend_from_slice(&(900000 + i).to_le_bytes()); // tick
        }
        out
    };
    let tampered = NativeGeidIndex::parse_legacy(&tampered_bytes).expect("tampered index still decodes");
    let broken = session.nested_correlation(tampered);
    assert!(
        broken.native_for_step(StepId(3)).is_none(),
        "tampered native index (GEIDs 9000..) must NOT resolve step 3 — proves the PASS is non-vacuous"
    );
    // And the join GEID 1001 is not an exact hit in the tampered index.
    assert!(broken.native().resolve_exact(1001).is_none(), "join GEID 1001 absent from the tampered index");
    eprintln!("[N2 tamper] real index resolves step 3; tampered (GEIDs 9000..) resolves nothing (non-vacuous)");
}

/// (3) Guard: the fixtures are present (fails clearly if they move).
#[test]
fn verify_nested_mcr_fixtures_present() {
    let dir = fixture_dir();
    assert!(
        dir.join("gdscript_trace.ct").is_file() && dir.join("native_geid.idx").is_file(),
        "N2 fixtures missing under {} — see the file header",
        dir.display()
    );
}
