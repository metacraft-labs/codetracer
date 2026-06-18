//! M29 §5.1 — Cross-process composer wired into the production
//! materialised + omniscient origin chain dispatchers.
//!
//! Pins the integration point per the M29 closure piece 1/5:
//! `cross_process_origin::run` is invoked from the per-backend
//! algorithms when the dispatcher hands them a session-wide
//! [`PairIndex`] + sibling-chain resolver. The composer detects the
//! receive marker the chain's tail hop sits on, looks up the matching
//! Send marker in the supplied two-trace fixture, and splices the
//! sibling hops into the chain (a `crossProcessSpan` is appended per
//! spec §14.3).
//!
//! Two integration tests live here:
//!
//! 1. `test_omniscient_dispatcher_extends_chain_with_cross_process_hops`
//!    — drives [`db_backend::omniscient_origin::run_omniscient_origin_chain_with_cross_process`]
//!    against a synthetic in-FFI omniscient log + a synthetic
//!    [`PairIndex`] carrying one Send/Recv pair across two recording
//!    ids. Asserts the returned chain carries a `crossProcessSpan`
//!    entry for each side of the boundary.
//! 2. `test_omniscient_dispatcher_passthrough_when_no_extension`
//!    — same fixture but no extension; pins the no-regression
//!    contract for single-trace chains (the wiring is a passthrough).
//!
//! The materialized algorithm shares the same composer entry point
//! (`cross_process_origin::run`) and is exercised at the unit-test
//! level in `src/db-backend/src/cross_process_origin.rs` against
//! synthetic chains; the M29 ship-core deliverables explicitly defer
//! the per-backend recorder-driven fixtures to the follow-on matrix
//! work (see `Value-Origin-Tracking.milestones.org` :deferred_items:
//! under M29).

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use db_backend::correlation_index::{MarkerEventView, PairIndex};
use db_backend::correlation_markers::{MarkerDirection, MarkerPayload};
use db_backend::cross_process_origin::{
    CrossProcessExtension, SiblingChainResolver, SiblingContinuation, TraceIdentity,
};
use db_backend::emulator_ffi;
use db_backend::omniscient_db::{FfiOmniscientDb, WriteRecord, omniscient_ffi_lock};
use db_backend::omniscient_origin::{MCR_OMNISCIENT_DEFAULT_MAX_HOPS, run_omniscient_origin_chain_with_cross_process};
use db_backend::task::{
    CtOriginChainArguments, DEFAULT_ORIGIN_MAX_STEPS_SCANNED, DEFAULT_ORIGIN_WALL_CLOCK_MS, Location, OriginBudget,
    OriginHop, OriginKind, Terminator, TerminatorKind,
};

const FE_RECORDING: &str = "rec-fe-m29-wiring";
const BE_RECORDING: &str = "rec-be-m29-wiring";
const BOUNDARY_ID: &str = "balance-request";
const MATCH_KEY: &str = "user-42";

fn ensure_nim_runtime() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| unsafe {
        emulator_ffi::NimMain();
    });
}

fn reset_nim_state() {
    ensure_nim_runtime();
    // SAFETY: idempotent module-level resets; the Nim shims tolerate
    // an uninitialised module state.
    unsafe {
        emulator_ffi::mcrOmniscientReset();
        emulator_ffi::mcrUndoMapReset();
    }
}

fn default_budget() -> OriginBudget {
    OriginBudget {
        max_hops: MCR_OMNISCIENT_DEFAULT_MAX_HOPS,
        wall_clock_ms: DEFAULT_ORIGIN_WALL_CLOCK_MS,
        max_steps_scanned: DEFAULT_ORIGIN_MAX_STEPS_SCANNED,
    }
}

/// Build a [`MarkerEventView`] whose `source_path` matches the
/// omniscient hop builder's default empty-path output. The composer's
/// substrate test in
/// `cross_process_origin::find_receive_marker_for_tail` matches the
/// hop's `location.path` against `ev.source_path` exactly, and the
/// omniscient hop builder produces hops with `Location::default()`
/// (i.e. `path = ""`) — so the synthetic marker mirrors that to fire
/// the composer's boundary detection.
fn marker_view(
    recording_id: &str,
    step_id: i64,
    direction: MarkerDirection,
    key_value: &str,
    show_value: Option<&str>,
) -> MarkerEventView {
    let payload = MarkerPayload {
        marker_id: 0,
        boundary_id: BOUNDARY_ID.to_string(),
        direction,
        key_text: "user_id".to_string(),
        key_value: key_value.to_string(),
        show_text: show_value.map(|_| "user_id".to_string()),
        show_value: show_value.map(String::from),
        description: Some(format!("M29 wiring fixture: {} marker", direction.as_str())),
        format: None,
    };
    // Empty source path mirrors the omniscient hop builder's
    // `Location::default()` output so the composer's substrate test
    // matches the chain's tail hop.
    MarkerEventView::new(recording_id, step_id, "", 0, payload)
}

/// Sibling-side hop the resolver returns — represents the backend's
/// final-write hop on the Send side of the boundary.
fn backend_sibling_hop(step_id: i64) -> OriginHop {
    OriginHop {
        kind: OriginKind::FieldAccess,
        target_expr: "user_id".to_string(),
        source_expr: "db_row.balance".to_string(),
        source_variable: Some("db_row".to_string()),
        location: Location {
            path: "backend/server.py".to_string(),
            line: 5,
            ..Location::default()
        },
        source_text: "payload = web.json_response({'balance': db_row.balance})".to_string(),
        step_id,
        frame_transition: None,
        operand_snapshots: Vec::new(),
        truncated_operands: false,
        confidence: 0.9,
        classification_provenance: Some("built-in: M29 wiring fixture".to_string()),
        correlation_transition: None,
    }
}

/// Two-trace pair index: one Recv marker in the frontend trace + one
/// Send marker in the backend trace, both carrying the same
/// (boundary_id, key_value) so the composer pairs them.
fn build_two_trace_pair_index(fe_step: i64, be_step: i64) -> PairIndex {
    PairIndex::build(&[
        marker_view(FE_RECORDING, fe_step, MarkerDirection::Recv, MATCH_KEY, Some(MATCH_KEY)),
        marker_view(BE_RECORDING, be_step, MarkerDirection::Send, MATCH_KEY, Some(MATCH_KEY)),
    ])
}

/// Seed the omniscient log with one write that will surface as the
/// chain's tail hop. The omniscient algorithm walks the log with
/// `last_write_before(.., tick)` (strict less-than per spec §6.5),
/// and the algorithm derives the initial cursor from `args.step_id`
/// interpreted as a tick (the M20 fixture pattern). To surface a hop
/// the seeded write's tick MUST be strictly less than `query_step`.
fn seed_omniscient_log_for_single_hop(query_step: i64) -> (CtOriginChainArguments, FfiOmniscientDb) {
    const ADDR: u64 = 0x6000;
    let db = FfiOmniscientDb::new();
    let seeded_tick = (query_step as u64).saturating_sub(5).max(1);
    assert!(db.push_write(WriteRecord {
        tick: seeded_tick,
        pc: 0xBEEF_0000,
        address: ADDR,
        size: 4,
        old_value: 0,
        new_value: 42,
    }));
    assert!(db.finalize());
    let args = CtOriginChainArguments {
        variable_name: format!("user_id@addr=0x{:x},size=4", ADDR),
        variable_path: Vec::new(),
        frame_id: -1,
        step_id: query_step,
        thread_id: 0,
        // Cap the chain at one hop so the omniscient walker terminates
        // immediately. The composer's substrate test in
        // `find_receive_marker_for_tail` works on the tail hop
        // regardless of how the chain terminated.
        max_hops: 1,
        lazy: false,
        continuation_token: None,
        session_id: String::new(),
        classify_source: true,
    };
    (args, db)
}

/// Drives the omniscient algorithm with the extension wired in;
/// asserts the chain ends up carrying a cross-process span entry +
/// the receive-side hop carries the M29 correlation-transition
/// metadata.
#[test]
fn test_omniscient_dispatcher_extends_chain_with_cross_process_hops() {
    let _guard = omniscient_ffi_lock().lock().unwrap_or_else(|p| p.into_inner());
    reset_nim_state();

    let fe_step: i64 = 12;
    let be_step: i64 = 7;
    let (args, db) = seed_omniscient_log_for_single_hop(fe_step);
    let pair_index = build_two_trace_pair_index(fe_step, be_step);

    // Count resolver invocations so the assertion below confirms the
    // composer actually drove the sibling-side path.
    let mut resolver_calls: u32 = 0;
    let mut resolver = |sibling_id: &str, step: i64, _display: &str| -> Option<SiblingContinuation> {
        resolver_calls += 1;
        assert_eq!(sibling_id, BE_RECORDING, "composer must dispatch to the sibling trace");
        assert_eq!(step, be_step, "composer must use the matched Send marker's step");
        Some(SiblingContinuation {
            sibling_identity: TraceIdentity::new(BE_RECORDING, "backend"),
            sibling_hops: vec![backend_sibling_hop(be_step)],
            sibling_terminator: Terminator::new(TerminatorKind::Computational),
            sibling_truncated: false,
        })
    };

    let extension = CrossProcessExtension {
        current_identity: TraceIdentity::new(FE_RECORDING, "frontend"),
        pair_index: &pair_index,
        resolver: &mut resolver as SiblingChainResolver,
    };

    let chain = run_omniscient_origin_chain_with_cross_process(&db, None, &args, &default_budget(), Some(extension))
        .expect("chain ok");

    assert_eq!(
        resolver_calls, 1,
        "composer must invoke the sibling resolver exactly once"
    );
    assert!(
        chain.hops.len() >= 2,
        "chain must include the frontend tail hop + the backend sibling hop, got {} hops",
        chain.hops.len()
    );

    // Spec §14.3: two cross-process spans — frontend (receive-side)
    // first, backend (send-side) second.
    assert_eq!(
        chain.cross_process_spans.len(),
        2,
        "cross-process spans: one per process, got {:?}",
        chain.cross_process_spans
    );
    let fe_span = &chain.cross_process_spans[0];
    let be_span = &chain.cross_process_spans[1];
    assert_eq!(fe_span.recording_id, FE_RECORDING);
    assert_eq!(fe_span.role, "frontend");
    assert_eq!(be_span.recording_id, BE_RECORDING);
    assert_eq!(be_span.role, "backend");
    assert!(
        be_span.first_hop_index >= fe_span.last_hop_index,
        "backend span must follow the frontend span: fe.last={} be.first={}",
        fe_span.last_hop_index,
        be_span.first_hop_index
    );

    // The boundary-crossing hop (the receive-side tail) must carry
    // the M29 correlation-transition descriptor pointing at the
    // matched Send marker in the backend trace.
    let receive_side_hop = chain.hops.get(fe_span.last_hop_index as usize).expect("recv-side hop");
    let transition = receive_side_hop
        .correlation_transition
        .as_ref()
        .expect("recv-side hop must carry the M29 correlation-transition descriptor");
    assert_eq!(transition.direction, "recv");
    assert_eq!(transition.correlated_recording_id, BE_RECORDING);
    assert_eq!(transition.correlated_step_id, be_step);
    assert_eq!(transition.boundary_id, BOUNDARY_ID);
    assert_eq!(transition.match_key_value, MATCH_KEY);

    // The composer replaces the receive-side terminator with the
    // sibling-side terminator (the backend's chain ended cleanly with
    // Computational).
    assert!(
        matches!(chain.terminator.kind, TerminatorKind::Computational),
        "terminator should be the sibling's (Computational), got {:?}",
        chain.terminator.kind
    );
}

/// Same fixture but `extension = None`: the wiring is a passthrough
/// and the chain is bit-identical to the single-trace shape (zero
/// `crossProcessSpan` entries).
#[test]
fn test_omniscient_dispatcher_passthrough_when_no_extension() {
    let _guard = omniscient_ffi_lock().lock().unwrap_or_else(|p| p.into_inner());
    reset_nim_state();

    let (args, db) = seed_omniscient_log_for_single_hop(12);
    let chain =
        run_omniscient_origin_chain_with_cross_process(&db, None, &args, &default_budget(), None).expect("chain ok");

    assert!(!chain.hops.is_empty(), "single-trace chain has at least one hop");
    assert!(
        chain.cross_process_spans.is_empty(),
        "no extension wired -> no cross-process spans, got {:?}",
        chain.cross_process_spans
    );
    assert!(
        chain.hops.iter().all(|h| h.correlation_transition.is_none()),
        "no hop should carry a correlation_transition when no extension is supplied"
    );
}
