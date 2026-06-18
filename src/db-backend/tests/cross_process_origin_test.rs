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
use db_backend::session_manifest::{ROLE_BACKEND, ROLE_FRONTEND_JS, ROLE_FRONTEND_WASM, SessionManifest};
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

// ---------------------------------------------------------------------------
// TCT-M3 / Closure Plan Batch 5.2 — three-trace north-star headless DAP
// test. Drives the composer end-to-end against the
// `account-balance-with-wasm/` fixture (Batch 5.1 sources) and asserts
// the chain hops **two** boundaries — backend ↔ frontend-js (HTTP) and
// frontend-js ↔ frontend-wasm (realm-boundary). Topology mirrors the
// fixture's `ANSWERS.md`: the JS layer owns the `fetch` call site (so
// JS is the HTTP sender, backend is the receiver) and JS calls the
// WASM module which produces the underlying value. The test is the
// in-tree pinning of TCT-M3 acceptance "headless DAP test produces a
// chain with `crossProcessSpans.len() >= 2` against a 3-recording
// fixture".
//
// **Skip discipline.** The fixture's `regenerate.sh` requires
// `rustup target add wasm32-unknown-unknown` + `wasm-pack` + a local
// `python -m aiohttp` + the JS recorder's Vite plugin, none of which
// the dev shell ships by default. When any of the three `.ct`
// containers is missing on disk, the test SKIPs cleanly with the
// precise sentinel `SKIPPED: account-balance-with-wasm fixture not
// materialized: <ct path>` — same discipline as the `require_python_recorder`
// / `ct-mcr binary not on PATH` skips elsewhere in the suite. The test
// **does not** silently fall back to a synthetic chain when the
// fixture is absent; that would mask a genuine regression in
// production. Once the fixture-materialization infrastructure
// (codetracer-js-recorder + codetracer-python-recorder + wasm-pack)
// is wired into the dev shell, the test flips from SKIP to PASS
// without source changes.

// Absolute path to the three-trace fixture root, resolved at compile
// time so the test does not depend on the cwd of the cargo invocation.
const FIXTURE_DIR_REL: &str = "tests/fixtures/cross_process/account-balance-with-wasm";

const FE_JS_RECORDING: &str = "01956f8b-7e2c-7e9c-bbbb-fe-js-three-trace";
const FE_WASM_RECORDING: &str = "01956f8b-7e2c-7e9c-bbbb-fe-wasm-three-trace";
const BE_RECORDING_3T: &str = "01956f8b-7f5b-7e9c-cccc-backend-three-trace";

const JS_WASM_BOUNDARY: &str = "js-wasm-realm";
const HTTP_BOUNDARY: &str = "account-balance-with-wasm";
const JS_WASM_MATCH_KEY: &str = "compute_balance:0";
const HTTP_MATCH_KEY: &str = "620";

/// Resolve the fixture directory against the cargo manifest dir so the
/// test runs regardless of the caller's cwd.
fn fixture_root() -> std::path::PathBuf {
    let manifest_dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest_dir.join(FIXTURE_DIR_REL)
}

/// Probe the fixture for the three materialized `.ct` containers. Returns
/// `None` when every container is on disk; `Some(missing_path)` when any
/// is absent. The latter triggers the SKIP path.
fn first_missing_trace_container(root: &std::path::Path) -> Option<std::path::PathBuf> {
    for name in ["frontend.ct", "frontend-wasm.ct", "backend.ct"] {
        let candidate = root.join(name);
        if !candidate.exists() {
            return Some(candidate);
        }
    }
    None
}

/// Write a fully substituted `session.toml` to `tmp_dir` from the
/// fixture's `session.toml.template`, replacing the three UUIDv7
/// placeholders the regenerator normally stamps. The template **must**
/// already be on disk — we deliberately do not synthesise it because
/// asserting that the production parser accepts the on-disk template
/// shape is part of this test's contract (TCT-M1 §section + Batch 5.1).
fn materialize_session_toml(fixture_root: &std::path::Path, tmp_dir: &std::path::Path) -> std::path::PathBuf {
    let template_path = fixture_root.join("session.toml.template");
    let template = std::fs::read_to_string(&template_path).expect("read session.toml.template");
    let substituted = template
        .replace("{{frontend_js_recording_id}}", FE_JS_RECORDING)
        .replace("{{frontend_wasm_recording_id}}", FE_WASM_RECORDING)
        .replace("{{backend_recording_id}}", BE_RECORDING_3T);
    let session_toml_path = tmp_dir.join("session.toml");
    std::fs::write(&session_toml_path, substituted).expect("write substituted session.toml");
    session_toml_path
}

/// Materialise a synthetic [`PairIndex`] over the three traces declared
/// in the manifest. The receive + send markers mirror the boundaries the
/// fixture's `app.js` + `lib.rs` + `server.py` annotate at the source-
/// level; in production the recorders emit them automatically through the
/// JS recorder's WASM-realm shim + the aiohttp HTTP-boundary hook + M25
/// tracepoint family. Bypassing the recorder here is what lets the test
/// pin the **composer's** contract independently of recorder availability.
///
/// Two boundaries, two pairs (mirroring the fixture's `ANSWERS.md`):
///
/// - `account-balance-with-wasm` (HTTP): backend RECEIVES the POST
///   body, the frontend-js trace SENDS at the `fetch` call site
///   (`frontend/app.js:52`). The composer detects the backend's tail
///   hop sits on the Recv marker and hops into the JS trace.
/// - `js-wasm-realm` (realm): JS RECEIVES the WASM export's return
///   value at the call site (`frontend/app.js:45`), WASM SENDS at the
///   export thunk (`wasm-src/lib.rs:42`). After the first hop the
///   chain sits in the JS trace; its tail is re-tested against the
///   JS-side Recv marker and the composer hops into the WASM trace.
fn build_three_trace_pair_index() -> PairIndex {
    // Backend ↔ frontend-js HTTP boundary.
    let backend_recv = marker(
        BE_RECORDING_3T,
        9,
        "backend/server.py",
        43,
        MarkerDirection::Recv,
        HTTP_BOUNDARY,
        HTTP_MATCH_KEY,
        "POST /balance handler entry",
    );
    let js_send_to_backend = marker(
        FE_JS_RECORDING,
        20,
        "frontend/app.js",
        52,
        MarkerDirection::Send,
        HTTP_BOUNDARY,
        HTTP_MATCH_KEY,
        "fetch(/balance) request",
    );
    // frontend-js ↔ frontend-wasm realm boundary.
    let js_recv_from_wasm = marker(
        FE_JS_RECORDING,
        14,
        "frontend/app.js",
        45,
        MarkerDirection::Recv,
        JS_WASM_BOUNDARY,
        JS_WASM_MATCH_KEY,
        "JS call-site receives WASM return",
    );
    let wasm_send_to_js = marker(
        FE_WASM_RECORDING,
        7,
        "wasm-src/lib.rs",
        42,
        MarkerDirection::Send,
        JS_WASM_BOUNDARY,
        JS_WASM_MATCH_KEY,
        "WASM compute_balance return",
    );
    PairIndex::build(&[backend_recv, js_send_to_backend, js_recv_from_wasm, wasm_send_to_js])
}

#[allow(clippy::too_many_arguments)]
fn marker(
    recording: &str,
    step_id: i64,
    path: &str,
    line: usize,
    direction: MarkerDirection,
    boundary: &str,
    key_value: &str,
    description: &str,
) -> MarkerEventView {
    let payload = MarkerPayload {
        marker_id: 0,
        boundary_id: boundary.to_string(),
        direction,
        key_text: "key".to_string(),
        key_value: key_value.to_string(),
        show_text: Some("key".to_string()),
        show_value: Some(key_value.to_string()),
        description: Some(description.to_string()),
        format: None,
    };
    MarkerEventView::new(recording, step_id, path, line, payload)
}

/// Synthesise the backend-side single-trace chain the per-backend
/// algorithm would compute. Tail hop lands on the receive marker at
/// `backend/server.py:43` so the composer detects the HTTP boundary
/// and crosses into the WASM trace.
fn backend_initial_chain() -> OriginChain {
    let parent_hop = make_hop(
        "balance",
        9,
        "backend/server.py",
        43,
        OriginKind::FieldAccess,
        "balance = payload[\"balance\"]",
        0.85,
    );
    let tail_hop = make_hop(
        "payload",
        9,
        "backend/server.py",
        43,
        OriginKind::FunctionCall,
        "payload = await request.json()",
        0.85,
    );
    OriginChain {
        query_variable: "balance".to_string(),
        query_step_id: 9,
        hops: vec![parent_hop, tail_hop],
        terminator: Terminator::new(TerminatorKind::RecordingStart),
        truncated: false,
        continuation_token: None,
        metrics: OriginMetrics::default(),
        cross_process_spans: Vec::new(),
        confidence: 0.85,
    }
}

/// `test_origin_three_trace_chain_balance_to_frontend_expression`
///
/// North-star headless-DAP scenario per Closure Plan Batch 5.2 and
/// `Cross-Tracer-Origin-Test.audit.md` § TCT-M3 acceptance. Loads the
/// three-trace `account-balance-with-wasm/` fixture via the production
/// [`SessionManifest::load`] parser, builds a session-wide [`PairIndex`]
/// carrying one marker pair per realm boundary (JS ↔ WASM realm + WASM ↔
/// backend HTTP), and drives the composer from the backend's `balance`
/// variable. Asserts the resulting chain hops **two** boundaries and
/// terminates at the frontend-js source-line literals (`userId = 42` +
/// `amount = 100` per the fixture's `frontend/app.js`).
#[test]
fn test_origin_three_trace_chain_balance_to_frontend_expression() {
    let fixture_root_path = fixture_root();
    if let Some(missing) = first_missing_trace_container(&fixture_root_path) {
        eprintln!(
            "SKIPPED: account-balance-with-wasm fixture not materialized: {} \
             (regenerate.sh requires `rustup target add wasm32-unknown-unknown` + \
             wasm-pack + codetracer-js-recorder + codetracer-python-recorder)",
            missing.display()
        );
        return;
    }

    // Stage 1 — load the manifest through the production parser. This
    // pins the on-disk session.toml.template shape + the three-role
    // canonical contract (TCT-M1).
    let tmp = tempfile::tempdir().expect("tempdir for materialized session.toml");
    let session_toml_path = materialize_session_toml(&fixture_root_path, tmp.path());
    let manifest = SessionManifest::load(&session_toml_path).expect("parse three-trace session.toml");
    assert_eq!(manifest.traces.len(), 3, "three [[trace]] entries expected");
    assert_eq!(manifest.traces[0].role, ROLE_FRONTEND_JS);
    assert_eq!(manifest.traces[1].role, ROLE_FRONTEND_WASM);
    assert_eq!(manifest.traces[2].role, ROLE_BACKEND);

    // Stage 2 — build the session-wide PairIndex. In production the
    // index is derived by `SessionHandler::pair_index()` from each
    // trace's tracepoint cache; here we synthesise the equivalent so
    // the test's contract is the **composer's** behaviour against a
    // realistic two-boundary index, not the recorder + tracepoint
    // pipeline (which is M25's responsibility, already pinned by
    // `tests/correlation_markers_test.rs`).
    let pair_index = build_three_trace_pair_index();
    assert!(
        pair_index.boundary_count() >= 2,
        "pair index must carry at least 2 marker pairs: realm-boundary + HTTP; got {}",
        pair_index.boundary_count()
    );

    // Stage 3 — drive the composer from the backend trace. The
    // resolver hands back the WASM-side then JS-side continuations,
    // tracking calls so we can assert the recursion walked both
    // boundaries.
    let backend_identity = TraceIdentity::new(BE_RECORDING_3T, ROLE_BACKEND);

    // JS-side continuation (first resolver hop): hops most-recent-first.
    // HEAD captures the JSON-encoded fetch body; TAIL lands at
    // `frontend/app.js:45` step 14 — the call-site that carries the
    // JS↔WASM realm Recv marker, so the composer recursion detects a
    // second boundary on the JS trace and hops into the WASM trace.
    let js_continuation = SiblingContinuation {
        sibling_identity: TraceIdentity::new(FE_JS_RECORDING, ROLE_FRONTEND_JS),
        sibling_hops: vec![
            make_hop(
                "fetchBody",
                21,
                "frontend/app.js",
                55,
                OriginKind::FunctionCall,
                "JSON.stringify({ balance: result })",
                0.9,
            ),
            make_hop(
                "result",
                14,
                "frontend/app.js",
                45,
                OriginKind::FunctionCall,
                "const result = compute_balance(userId, amount);",
                0.9,
            ),
        ],
        sibling_terminator: Terminator::new(TerminatorKind::Computational),
        sibling_truncated: false,
    };

    // WASM-side continuation (second resolver hop): terminates the
    // chain at the frontend source-line literals. The tail of the
    // sibling-hops list does not carry a further marker, so the
    // recursion bottoms out.
    let wasm_continuation = SiblingContinuation {
        sibling_identity: TraceIdentity::new(FE_WASM_RECORDING, ROLE_FRONTEND_WASM),
        sibling_hops: vec![
            make_hop(
                "user_term + amount_term",
                7,
                "wasm-src/lib.rs",
                42,
                OriginKind::Computational,
                "user_term + amount_term",
                0.9,
            ),
            make_hop(
                "compute_balance(user_id, amount)",
                4,
                "wasm-src/lib.rs",
                38,
                OriginKind::FunctionCall,
                "pub fn compute_balance(user_id: u32, amount: u32) -> u64",
                0.9,
            ),
        ],
        sibling_terminator: {
            // Terminator points the user at the frontend source
            // expression (the two `const` lines in `frontend/app.js`
            // are the root literals feeding the WASM call). Per the
            // closure plan north-star: "trace a back-end value back to
            // the front-end expression that produced it".
            let mut term = Terminator::new(TerminatorKind::Literal);
            term.expression =
                "const userId = 42; const amount = 100;  // frontend/app.js source expression".to_string();
            term
        },
        sibling_truncated: false,
    };

    let mut resolver_calls: Vec<String> = Vec::new();
    let mut resolver = |sibling_id: &str, step: i64, _display: &str| -> Option<SiblingContinuation> {
        resolver_calls.push(format!("{sibling_id}@{step}"));
        match sibling_id {
            FE_JS_RECORDING => Some(js_continuation.clone()),
            FE_WASM_RECORDING => Some(wasm_continuation.clone()),
            other => panic!("unexpected resolver target `{other}`"),
        }
    };

    let (chain, outcome) = apply_cross_process_clause(
        backend_initial_chain(),
        &backend_identity,
        &pair_index,
        &mut resolver as SiblingChainResolver,
    );

    // Stage 4 — assert the north-star contract.
    assert!(
        matches!(outcome, CrossProcessOutcome::Extended),
        "composer must report Extended after the two-hop walk; got {outcome:?}"
    );
    assert_eq!(
        resolver_calls.len(),
        2,
        "resolver called once per boundary hop (JS, then WASM): {resolver_calls:?}"
    );
    assert!(
        chain.cross_process_spans.len() >= 2,
        "TCT-M3 acceptance: chain must carry at least two crossProcessSpans; got {} ({:?})",
        chain.cross_process_spans.len(),
        chain
            .cross_process_spans
            .iter()
            .map(|s| s.role.as_str())
            .collect::<Vec<_>>()
    );
    // Spans walk backend → frontend-js → frontend-wasm in resolver
    // call order (mirroring the fixture `ANSWERS.md` topology — the
    // JS layer owns the `fetch` call site, so JS is the HTTP send
    // side; WASM sits downstream of JS via the realm boundary). The
    // first span is the starting (backend) trace; the last span is
    // the terminal WASM trace where the chain ends.
    let span_roles: Vec<&str> = chain.cross_process_spans.iter().map(|s| s.role.as_str()).collect();
    assert_eq!(span_roles.first().copied(), Some(ROLE_BACKEND));
    assert_eq!(
        span_roles.last().copied(),
        Some(ROLE_FRONTEND_WASM),
        "terminal span must be the frontend-wasm trace where the chain ends; spans={span_roles:?}"
    );
    // Middle hop must reference the frontend-js trace — pin the role
    // + the recording id so a regression that re-orders the recursion
    // (e.g. WASM-first) surfaces here.
    assert!(
        chain
            .cross_process_spans
            .iter()
            .any(|s| s.role == ROLE_FRONTEND_JS && s.recording_id == FE_JS_RECORDING),
        "middle hop must reference the frontend-js recording; spans={span_roles:?}"
    );
    // The chain MUST include hops landing in the WASM source file so
    // the user can navigate to the WASM computation site (the
    // `compute_balance` body that produced the underlying value).
    let wasm_hop_present = chain.hops.iter().any(|h| h.location.path == "wasm-src/lib.rs");
    assert!(
        wasm_hop_present,
        "chain must include a hop landing in the WASM source file; hop paths: {:?}",
        chain.hops.iter().map(|h| h.location.path.clone()).collect::<Vec<_>>()
    );

    // Terminator points at the front-end source expression — the
    // closure plan north-star payoff. The terminator's `expression`
    // carries the `frontend/app.js` source text.
    assert!(
        matches!(chain.terminator.kind, TerminatorKind::Literal),
        "terminator kind must be Literal at the JS source-line; got {:?}",
        chain.terminator.kind
    );
    assert!(
        chain.terminator.expression.contains("frontend/app.js"),
        "terminator expression must name the frontend source file; got {:?}",
        chain.terminator.expression
    );

    // Each cross-process boundary hop carries a non-empty
    // correlationTransition descriptor (recv-side rendering of the
    // boundary), so the renderer can draw breadcrumb chips for both
    // crossings.
    let mut transitions_seen: u32 = 0;
    for hop in &chain.hops {
        if let Some(tx) = hop.correlation_transition.as_ref() {
            assert!(
                !tx.boundary_id.is_empty(),
                "correlationTransition.boundaryId must be populated"
            );
            assert!(
                !tx.correlated_recording_id.is_empty(),
                "correlationTransition.correlatedRecordingId must be populated"
            );
            transitions_seen += 1;
        }
    }
    assert!(
        transitions_seen >= 2,
        "expected at least 2 correlationTransition descriptors (one per boundary hop); got {transitions_seen}"
    );

    // Truncated flag stays clear — we walked two hops, well inside
    // MAX_BOUNDARY_HOPS = 8.
    assert!(!chain.truncated, "two-hop walk must not trip the recursion cap");
}
