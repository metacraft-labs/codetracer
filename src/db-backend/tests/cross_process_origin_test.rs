//! M29 — Cross-process origin E2E tests (Headless DAP layer §5.1 of
//! the Cross-Process Origin E2E Test Design doc).
//!
//! These tests pin the §14.3 cross-process clause + serialisation-
//! aware copy tracking + ambiguous/missing correlation handling at
//! the integration level. They drive the
//! [`db_backend::cross_process_origin::apply_cross_process_clause`]
//! composer the dispatcher invokes after each per-backend single-
//! trace algorithm.
//!
//! ## Test naming and scope
//!
//! Names mirror the M29 verification entries in
//! `Value-Origin-Tracking.milestones.org`. Six tests are shipped at
//! integration scope (per the M29 "ship core" directive); the
//! per-backend matrix (Ruby webrick, Node http, C/libmicrohttpd,
//! Rust/hyper, Go/net/http) is deferred until the recorder-driven
//! fixture-regeneration infrastructure described in the design doc
//! §3.4 lands. See the M29 PROPERTIES status for the explicit defer
//! list.
//!
//! ## Fixture strategy
//!
//! Each test synthesises an in-memory `PairIndex` carrying the
//! receive + send markers a real recording pair would produce, and
//! supplies a `SiblingChainResolver` callback that returns canned
//! sibling-side hops mirroring the canonical Fixture A "Account
//! Balance" chain shape (frontend `balance` → backend
//! `db_row.balance`). The receive-side chain is also synthesised so
//! the test focuses on the composer's behaviour rather than on the
//! per-backend single-trace path; the per-backend tests in
//! `origin_*_dap_test.rs` already exercise that path end-to-end. This
//! mirrors the M25 strategy of synthesising marker firings for the
//! pair-index tests instead of spinning up live recorders for every
//! pair-index assertion.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use db_backend::correlation_index::{MarkerEventView, PairIndex};
use db_backend::correlation_markers::{MarkerDirection, MarkerPayload};
use db_backend::cross_process_origin::{
    CrossProcessOutcome, SiblingChainResolver, SiblingContinuation, TraceIdentity, apply_cross_process_clause,
};
use db_backend::task::{Location, OriginChain, OriginHop, OriginKind, OriginMetrics, Terminator, TerminatorKind};

// ---------------------------------------------------------------------------
// Test-fixture helpers — Fixture A (Account Balance) per E2E design doc §3.1.
// ---------------------------------------------------------------------------

const FE_RECORDING: &str = "rec-fe-account-balance";
const BE_RECORDING: &str = "rec-be-account-balance-py-aiohttp";
const BOUNDARY_ID: &str = "balance-request";
const MATCH_KEY: &str = "user-42";

fn fe_recv_marker(step_id: i64) -> MarkerEventView {
    let payload = MarkerPayload {
        marker_id: 1,
        boundary_id: BOUNDARY_ID.to_string(),
        direction: MarkerDirection::Recv,
        key_text: "userId".to_string(),
        key_value: MATCH_KEY.to_string(),
        show_text: Some("user_id".to_string()),
        show_value: Some(MATCH_KEY.to_string()),
        description: Some("GET /api/balance handler".to_string()),
        format: None,
    };
    MarkerEventView::new(FE_RECORDING, step_id, "frontend/app.js", 3, payload)
}

fn be_send_marker(step_id: i64) -> MarkerEventView {
    let payload = MarkerPayload {
        marker_id: 2,
        boundary_id: BOUNDARY_ID.to_string(),
        direction: MarkerDirection::Send,
        key_text: "user_id".to_string(),
        key_value: MATCH_KEY.to_string(),
        show_text: Some("user_id".to_string()),
        show_value: Some(MATCH_KEY.to_string()),
        description: Some("GET /api/balance request".to_string()),
        format: None,
    };
    MarkerEventView::new(BE_RECORDING, step_id, "backend/server.py", 5, payload)
}

fn make_hop(
    target: &str,
    step_id: i64,
    path: &str,
    line: i64,
    kind: OriginKind,
    source_text: &str,
    confidence: f32,
) -> OriginHop {
    OriginHop {
        kind,
        target_expr: target.to_string(),
        source_expr: source_text.to_string(),
        source_variable: None,
        location: Location {
            path: path.to_string(),
            line,
            ..Location::default()
        },
        source_text: source_text.to_string(),
        step_id,
        frame_transition: None,
        operand_snapshots: Vec::new(),
        truncated_operands: false,
        confidence,
        classification_provenance: Some("built-in: test fixture".to_string()),
        correlation_transition: None,
    }
}

/// Build a synthetic frontend-side single-trace chain ending at the
/// receive marker — mirrors the "balance" chain from Fixture A
/// ANSWERS.md (truncated to the section the composer sees as input).
fn make_frontend_chain(mode_3: bool) -> OriginChain {
    let mut conf = if mode_3 { 0.95 } else { 0.7 };
    if mode_3 {
        conf = 0.95;
    }
    let tail_hop_step = 12;
    let tail_hop = make_hop(
        "payload",
        tail_hop_step,
        "frontend/app.js",
        3,
        OriginKind::FunctionCall,
        "payload = await response.json()",
        conf,
    );
    let parent_hop = make_hop(
        "balance",
        14,
        "frontend/app.js",
        4,
        OriginKind::FieldAccess,
        "balance = payload.balance",
        conf,
    );
    OriginChain {
        query_variable: "balance".to_string(),
        query_step_id: 14,
        // hops most-recent-first; the parent assignment is index 0,
        // the receive-side tail is the last entry.
        hops: vec![parent_hop, tail_hop],
        terminator: Terminator::new(TerminatorKind::RecordingStart),
        truncated: false,
        continuation_token: None,
        metrics: OriginMetrics::default(),
        cross_process_spans: Vec::new(),
        confidence: conf,
    }
}

/// Canonical backend-side hops for Fixture A — appended by the
/// composer.
fn fixture_a_backend_hops() -> Vec<OriginHop> {
    vec![
        make_hop(
            "payload",
            6,
            "backend/server.py",
            6,
            OriginKind::FunctionCall,
            "return web.json_response(payload)",
            0.9,
        ),
        make_hop(
            "payload",
            5,
            "backend/server.py",
            5,
            OriginKind::Computational,
            "payload = {\"balance\": db_row.balance}",
            0.85,
        ),
        make_hop(
            "db_row.balance",
            4,
            "backend/server.py",
            4,
            OriginKind::FieldAccess,
            "db_row = await db.fetch_one(...)",
            0.8,
        ),
    ]
}

/// Resolver factory: returns canned Fixture A backend continuation.
fn fixture_a_resolver() -> impl FnMut(&str, i64, &str) -> Option<SiblingContinuation> {
    move |sibling_id: &str, _step: i64, _display: &str| -> Option<SiblingContinuation> {
        // `_step` is the sibling-side resume step — a real
        // resolver feeds it to the per-backend single-trace path
        // (here we ignore it because the fixture's hop list is
        // canned).
        if sibling_id != BE_RECORDING {
            return None;
        }
        let mut term = Terminator::new(TerminatorKind::Computational);
        term.expression = "db.fetch_one(...)".to_string();
        Some(SiblingContinuation {
            sibling_identity: TraceIdentity::new(BE_RECORDING, "backend"),
            sibling_hops: fixture_a_backend_hops(),
            sibling_terminator: term,
            sibling_truncated: false,
        })
    }
}

// ---------------------------------------------------------------------------
// Tests (per M29 verification block, §5.1 of the E2E design doc).
// ---------------------------------------------------------------------------

/// `test_origin_cross_process_fixture_a_python_aiohttp_mode1`
///
/// Mode 1 — no origin-metadata streams. Asserts the full chain shape
/// (including the `CrossProcessSpan` matching and the
/// `correlation_transition` field check on the boundary-crossing hop).
#[test]
fn test_origin_cross_process_fixture_a_python_aiohttp_mode1() {
    let pair_index = PairIndex::build(&[fe_recv_marker(12), be_send_marker(6)]);
    let chain = make_frontend_chain(false);

    let mut resolver_fn = fixture_a_resolver();
    let identity = TraceIdentity::new(FE_RECORDING, "frontend");
    let (chain, outcome) =
        apply_cross_process_clause(chain, &identity, &pair_index, &mut resolver_fn as SiblingChainResolver);

    assert!(matches!(outcome, CrossProcessOutcome::Extended));
    // 2 frontend + 3 backend hops = 5 hops.
    assert_eq!(chain.hops.len(), 5, "fixture A canonical hop count");
    assert_eq!(chain.cross_process_spans.len(), 2);
    assert_eq!(chain.cross_process_spans[0].role, "frontend");
    assert_eq!(chain.cross_process_spans[0].recording_id, FE_RECORDING);
    assert_eq!(chain.cross_process_spans[0].first_hop_index, 0);
    assert_eq!(chain.cross_process_spans[0].last_hop_index, 1);
    assert_eq!(chain.cross_process_spans[1].role, "backend");
    assert_eq!(chain.cross_process_spans[1].recording_id, BE_RECORDING);
    assert_eq!(chain.cross_process_spans[1].first_hop_index, 2);
    assert_eq!(chain.cross_process_spans[1].last_hop_index, 4);

    // The boundary-crossing hop is the tail of the frontend span
    // (index 1). It carries the correlation_transition.
    let boundary_hop = &chain.hops[1];
    let tx = boundary_hop
        .correlation_transition
        .as_ref()
        .expect("boundary hop carries correlation_transition");
    assert_eq!(tx.boundary_id, BOUNDARY_ID);
    assert_eq!(tx.match_key_value, MATCH_KEY);
    assert_eq!(tx.correlated_recording_id, BE_RECORDING);
    assert_eq!(tx.correlated_step_id, 6);
    assert_eq!(tx.display_variable_value.as_deref(), Some(MATCH_KEY));
    assert_eq!(tx.direction, "recv");
    // §14.3 serialisation-aware re-labelling: the receive-side hop's
    // initial classifier verdict (`FunctionCall` for `await
    // response.json()`) collapses to `TrivialCopy` per spec §14.3.
    assert_eq!(boundary_hop.kind, OriginKind::TrivialCopy);

    // Terminator becomes the backend-side terminator.
    assert!(matches!(chain.terminator.kind, TerminatorKind::Computational));
    assert!(!chain.truncated);
}

/// `test_origin_cross_process_fixture_a_python_aiohttp_mode3`
///
/// Mode 3 — origin metadata streams present. Same chain shape; per-
/// hop confidences are higher (≥ Mode 1's). Mode 3 must not invoke
/// the classifier at query time. The composer-level surface does not
/// directly observe classifier invocations (that's the responsibility
/// of the per-backend single-trace algorithm); we verify the chain
/// shape parity here and the classifier-invocation contract in
/// `origin_omniscient_test.rs::mode_3_chain_skips_classifier_when_metadata_present`.
#[test]
fn test_origin_cross_process_fixture_a_python_aiohttp_mode3() {
    let pair_index = PairIndex::build(&[fe_recv_marker(12), be_send_marker(6)]);
    let chain = make_frontend_chain(true);

    let mut resolver_fn = fixture_a_resolver();
    let identity = TraceIdentity::new(FE_RECORDING, "frontend");
    let (chain, outcome) =
        apply_cross_process_clause(chain, &identity, &pair_index, &mut resolver_fn as SiblingChainResolver);

    assert!(matches!(outcome, CrossProcessOutcome::Extended));
    assert_eq!(chain.hops.len(), 5);
    assert!(chain.confidence >= 0.7, "mode 3 confidence ≥ mode 1's");
    // Spec: classifier invocations at chain-compute time, not at
    // composer time. The composer just relabels the receive-side
    // boundary hop.
    assert_eq!(chain.cross_process_spans.len(), 2);
}

/// `test_parity_origin_cross_process_fixture_a_python_aiohttp`
///
/// Mode 1 ↔ Mode 3 parity: identical chain shape; Mode 3 confidences
/// ≥ Mode 1's. Single test per the spec mandate (must not split into
/// two independent assertions).
#[test]
fn test_parity_origin_cross_process_fixture_a_python_aiohttp() {
    let pair_index_a = PairIndex::build(&[fe_recv_marker(12), be_send_marker(6)]);
    let chain_mode1 = make_frontend_chain(false);
    let mut resolver_a = fixture_a_resolver();
    let identity = TraceIdentity::new(FE_RECORDING, "frontend");
    let (chain_mode1, _) = apply_cross_process_clause(
        chain_mode1,
        &identity,
        &pair_index_a,
        &mut resolver_a as SiblingChainResolver,
    );

    let pair_index_b = PairIndex::build(&[fe_recv_marker(12), be_send_marker(6)]);
    let chain_mode3 = make_frontend_chain(true);
    let mut resolver_b = fixture_a_resolver();
    let (chain_mode3, _) = apply_cross_process_clause(
        chain_mode3,
        &identity,
        &pair_index_b,
        &mut resolver_b as SiblingChainResolver,
    );

    // Shape parity: same hop count, same kind sequence, same target
    // expression sequence.
    assert_eq!(
        chain_mode1.hops.len(),
        chain_mode3.hops.len(),
        "mode 1 and mode 3 must have identical hop counts"
    );
    let mut diffs: Vec<String> = Vec::new();
    for (i, (h1, h3)) in chain_mode1.hops.iter().zip(chain_mode3.hops.iter()).enumerate() {
        if h1.kind != h3.kind {
            diffs.push(format!("hop[{i}] kind: {:?} vs {:?}", h1.kind, h3.kind));
        }
        if h1.target_expr != h3.target_expr {
            diffs.push(format!(
                "hop[{i}] target_expr: {:?} vs {:?}",
                h1.target_expr, h3.target_expr
            ));
        }
        if h1.location.path != h3.location.path || h1.location.line != h3.location.line {
            diffs.push(format!(
                "hop[{i}] location: {}:{} vs {}:{}",
                h1.location.path, h1.location.line, h3.location.path, h3.location.line
            ));
        }
        assert!(
            h3.confidence >= h1.confidence,
            "hop[{}] mode 3 confidence ({}) must be ≥ mode 1's ({})",
            i,
            h3.confidence,
            h1.confidence
        );
    }
    assert!(
        diffs.is_empty(),
        "mode 1 ↔ mode 3 chain shape diverges: {}",
        diffs.join(", ")
    );

    // Cross-process spans + boundary hop transition shape must match.
    assert_eq!(
        chain_mode1.cross_process_spans.len(),
        chain_mode3.cross_process_spans.len()
    );
    let tx1 = chain_mode1.hops[1].correlation_transition.as_ref().unwrap();
    let tx3 = chain_mode3.hops[1].correlation_transition.as_ref().unwrap();
    assert_eq!(tx1.boundary_id, tx3.boundary_id);
    assert_eq!(tx1.match_key_value, tx3.match_key_value);
    assert_eq!(tx1.correlated_recording_id, tx3.correlated_recording_id);
    assert_eq!(tx1.correlated_step_id, tx3.correlated_step_id);
}

/// `test_origin_cross_process_serialisation_aware_json_collapses_to_trivial_copy`
///
/// The §14.3 serialisation-aware rule: the receive-side
/// `JSON.parse` / `response.json()` hop and the send-side
/// `JSON.stringify` / `web.json_response` hop are both classified as
/// `TrivialCopy` rather than opaque `FunctionCall`.
#[test]
fn test_origin_cross_process_serialisation_aware_json_collapses_to_trivial_copy() {
    let pair_index = PairIndex::build(&[fe_recv_marker(12), be_send_marker(6)]);
    // Frontend chain whose tail hop reads `payload = await response.json()`.
    let chain = make_frontend_chain(false);
    assert_eq!(
        chain.hops.last().unwrap().kind,
        OriginKind::FunctionCall,
        "pre-condition: receive-side hop starts as FunctionCall"
    );

    let mut resolver_fn = fixture_a_resolver();
    let identity = TraceIdentity::new(FE_RECORDING, "frontend");
    let (chain, _) =
        apply_cross_process_clause(chain, &identity, &pair_index, &mut resolver_fn as SiblingChainResolver);

    // Post-condition: the receive-side boundary hop is TrivialCopy.
    let boundary_hop = &chain.hops[1];
    assert_eq!(
        boundary_hop.kind,
        OriginKind::TrivialCopy,
        "JSON.parse/response.json() collapsed to TrivialCopy per spec §14.3"
    );
    assert!(
        boundary_hop
            .classification_provenance
            .as_deref()
            .unwrap_or_default()
            .contains("M29 §14.3 serialisation-aware"),
        "provenance carries the M29 §14.3 rule marker; got {:?}",
        boundary_hop.classification_provenance
    );
}

/// `test_origin_cross_process_ambiguous_correlation_terminates_cleanly`
///
/// Two send markers carry the same boundary + key — chain
/// terminates with `UnknownSource` + an explanatory expression. No
/// spurious sibling hops are appended.
#[test]
fn test_origin_cross_process_ambiguous_correlation_terminates_cleanly() {
    let send_a = be_send_marker(6);
    let mut send_b = be_send_marker(9);
    send_b.recording_id = "rec-be-second-service".to_string();
    let pair_index = PairIndex::build(&[fe_recv_marker(12), send_a, send_b]);

    let chain = make_frontend_chain(false);
    let original_hops = chain.hops.len();

    let mut resolver_fn = fixture_a_resolver();
    let identity = TraceIdentity::new(FE_RECORDING, "frontend");
    let (chain, outcome) =
        apply_cross_process_clause(chain, &identity, &pair_index, &mut resolver_fn as SiblingChainResolver);

    assert!(
        matches!(outcome, CrossProcessOutcome::AmbiguousCorrelation { candidates: 2 }),
        "outcome carries the candidate count; got {:?}",
        outcome
    );
    assert_eq!(chain.hops.len(), original_hops, "no sibling hops appended");
    assert!(
        matches!(chain.terminator.kind, TerminatorKind::UnknownSource),
        "terminator kind must be UnknownSource on ambiguous correlation"
    );
    assert!(
        chain.terminator.expression.contains("ambiguous"),
        "terminator carries explanatory expression; got {:?}",
        chain.terminator.expression
    );
}

/// `test_origin_cross_process_missing_correlation_terminates_cleanly`
///
/// No send marker matches the receive key — chain terminates with
/// `RecordingStart` in the sender direction. The receiver-side chain
/// is otherwise complete.
#[test]
fn test_origin_cross_process_missing_correlation_terminates_cleanly() {
    let pair_index = PairIndex::build(&[fe_recv_marker(12)]);
    let chain = make_frontend_chain(false);
    let original_hops = chain.hops.len();

    let mut resolver_fn = fixture_a_resolver();
    let identity = TraceIdentity::new(FE_RECORDING, "frontend");
    let (chain, outcome) =
        apply_cross_process_clause(chain, &identity, &pair_index, &mut resolver_fn as SiblingChainResolver);

    assert!(matches!(outcome, CrossProcessOutcome::MissingCorrelation));
    assert_eq!(chain.hops.len(), original_hops, "no sibling hops appended");
    assert!(matches!(chain.terminator.kind, TerminatorKind::RecordingStart));
    assert!(
        chain.terminator.expression.contains("no matching send"),
        "terminator carries explanatory expression; got {:?}",
        chain.terminator.expression
    );
}
