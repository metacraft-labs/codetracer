//! M29 — ViewModel-layer **wire-shape** tests for cross-process
//! origin chains (per §5.3 of the Cross-Process Origin E2E Test
//! Design doc).
//!
//! ## Why wire-shape tests
//!
//! The §5.3 entries in the M29 verification block target the Nim
//! `SessionVM` / `OriginChainVM` ViewModels under
//! `codetracer/src/frontend/tests/cross_process/`. The Nim test
//! runner is not invoked from `cargo test`; running the Nim
//! integration suite end-to-end requires the full `just build-once`
//! pipeline plus the embedded Electron renderer.
//!
//! Per the M29 ship-core directive ("focus on the core algorithm;
//! defer per-fixture matrices"), we ship a **Rust-side proxy** for
//! the two §5.3 tests the spec calls out as core. The ViewModel
//! reads the wire payload of `ct/listProcesses` + `ct/originChain`
//! and exposes them as reactive signals. The wire contract is
//! exactly what these tests pin: when the wire payload carries the
//! M29 fields (`processTree` from `ct/listProcesses`,
//! `crossProcessSpans` + `correlationTransition` on the
//! `OriginChain`), a downstream ViewModel can render the per-process
//! breadcrumb chips + the cross-process hop badge without round-
//! tripping through the backend again. The full Nim-layer
//! integration tests are tracked as a follow-on alongside the
//! recorder-driven fixture infrastructure (see the M29 PROPERTIES
//! defer list).
//!
//! ## Tests shipped
//!
//! 1. `test_session_vm_process_tree_populated_from_listprocesses` —
//!    the `ct/listProcesses` response shape matches what the
//!    ViewModel's `processTree` signal expects.
//! 2. `test_origin_chain_vm_renders_cross_process_spans` — the
//!    `ct/originChain` response shape carries `crossProcessSpans` +
//!    `correlationTransition` such that the ViewModel can render
//!    them without additional lookups.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use db_backend::correlation_index::{MarkerEventView, PairIndex};
use db_backend::correlation_markers::{MarkerDirection, MarkerPayload};
use db_backend::cross_process_origin::{
    SiblingChainResolver, SiblingContinuation, TraceIdentity, apply_cross_process_clause,
};
use db_backend::dap_handler::Handler;
use db_backend::db::Db;
use db_backend::recreator_session::RecreatorArgs;
use db_backend::session_handler::{SessionHandler, SessionHandlerError, TraceSlot, compose_thread_id};
use db_backend::session_manifest::{CorrelationConfig, RecordingId, SessionManifest, TraceEntry};
use db_backend::task::{
    Location, OriginChain, OriginHop, OriginKind, OriginMetrics, Terminator, TerminatorKind, TraceKind,
};
use std::path::PathBuf;

fn make_handler(name: &str) -> Handler {
    let args = RecreatorArgs {
        name: name.to_string(),
        ..RecreatorArgs::default()
    };
    Handler::new(TraceKind::Materialized, args, Box::new(Db::new(&PathBuf::from(""))))
}

fn two_trace_manifest() -> SessionManifest {
    SessionManifest {
        version: 1,
        traces: vec![
            TraceEntry {
                recording_id: RecordingId("rec-fe".to_string()),
                path: PathBuf::from("frontend.ct"),
                role: "frontend".to_string(),
                default_thread_prefix: "fe".to_string(),
            },
            TraceEntry {
                recording_id: RecordingId("rec-be".to_string()),
                path: PathBuf::from("backend.ct"),
                role: "backend".to_string(),
                default_thread_prefix: "be".to_string(),
            },
        ],
        correlation: CorrelationConfig::default(),
        base_dir: PathBuf::from("."),
    }
}

/// `test_session_vm_process_tree_populated_from_listprocesses`
///
/// The Nim `SessionVM.processTree` signal reads its rows directly
/// from the `ct/listProcesses` response. This test pins the wire
/// shape the ViewModel depends on: two entries, each carrying its
/// recording id + role + thread id list.
#[test]
fn test_session_vm_process_tree_populated_from_listprocesses() {
    let manifest = two_trace_manifest();
    let session =
        SessionHandler::new(manifest, vec![make_handler("frontend"), make_handler("backend")]).expect("session");

    let inner_lookup = |slot: TraceSlot| -> Result<Vec<(u32, String)>, SessionHandlerError> {
        match slot {
            0 => Ok(vec![(1, "thread-1".to_string())]),
            1 => Ok(vec![(1, "thread-1".to_string()), (2, "thread-2".to_string())]),
            other => Err(SessionHandlerError::UnknownSlot { slot: other }),
        }
    };
    let processes = session.list_processes(inner_lookup).expect("list_processes");

    // ViewModel-contract: two process tree rows.
    assert_eq!(processes.len(), 2);

    // Row 0 — frontend.
    assert_eq!(processes[0].recording_id, "rec-fe");
    assert_eq!(processes[0].role, "frontend");
    assert_eq!(processes[0].default_thread_prefix, "fe");
    assert_eq!(processes[0].thread_count, 1);
    assert_eq!(processes[0].thread_ids, vec![compose_thread_id(0, 1).unwrap()]);

    // Row 1 — backend.
    assert_eq!(processes[1].recording_id, "rec-be");
    assert_eq!(processes[1].role, "backend");
    assert_eq!(processes[1].default_thread_prefix, "be");
    assert_eq!(processes[1].thread_count, 2);
    assert_eq!(
        processes[1].thread_ids,
        vec![compose_thread_id(1, 1).unwrap(), compose_thread_id(1, 2).unwrap()]
    );

    // ViewModel-contract: process-tree shape round-trips through
    // JSON without losing any field. This is the exact byte shape
    // the Nim ViewModel deserialises.
    let json = serde_json::to_value(&processes).expect("serialise");
    assert_eq!(json[0]["recordingId"], "rec-fe");
    assert_eq!(json[0]["role"], "frontend");
    assert_eq!(json[1]["recordingId"], "rec-be");
    assert_eq!(json[1]["role"], "backend");
    assert_eq!(json[1]["threadCount"], 2);
}

fn fe_recv_marker() -> MarkerEventView {
    let payload = MarkerPayload {
        marker_id: 1,
        boundary_id: "balance-request".to_string(),
        direction: MarkerDirection::Recv,
        key_text: "userId".to_string(),
        key_value: "user-42".to_string(),
        show_text: Some("user_id".to_string()),
        show_value: Some("user-42".to_string()),
        description: Some("GET /api/balance handler".to_string()),
        format: None,
    };
    MarkerEventView::new("rec-fe", 12, "frontend/app.js", 3, payload)
}

fn be_send_marker() -> MarkerEventView {
    let payload = MarkerPayload {
        marker_id: 2,
        boundary_id: "balance-request".to_string(),
        direction: MarkerDirection::Send,
        key_text: "user_id".to_string(),
        key_value: "user-42".to_string(),
        show_text: Some("user_id".to_string()),
        show_value: Some("user-42".to_string()),
        description: Some("GET /api/balance request".to_string()),
        format: None,
    };
    MarkerEventView::new("rec-be", 6, "backend/server.py", 5, payload)
}

fn make_hop(target: &str, step_id: i64, path: &str, line: i64) -> OriginHop {
    OriginHop {
        kind: OriginKind::TrivialCopy,
        target_expr: target.to_string(),
        source_expr: format!("synthesised source for {target}"),
        source_variable: None,
        location: Location {
            path: path.to_string(),
            line,
            ..Location::default()
        },
        source_text: format!("{target} = expr"),
        step_id,
        frame_transition: None,
        operand_snapshots: Vec::new(),
        truncated_operands: false,
        confidence: 0.9,
        classification_provenance: Some("built-in: viewmodel wire-shape test".to_string()),
        correlation_transition: None,
    }
}

/// `test_origin_chain_vm_renders_cross_process_spans`
///
/// The `OriginChainVM.activeChain` field is populated from the
/// `ct/originChain` response. The Nim ViewModel renders the
/// per-process breadcrumb chips by reading `crossProcessSpans`; the
/// cross-process hop badge is rendered by reading the boundary
/// hop's `correlationTransition`. This test pins the wire shape
/// such that:
///
/// - `crossProcessSpans` is a non-empty array when the chain crosses
///   a process boundary, each entry carrying `recordingId`, `role`,
///   `firstHopIndex`, `lastHopIndex`.
/// - The boundary-crossing hop carries a `correlationTransition`
///   field with `boundaryId`, `matchKeyValue`, `correlatedRecordingId`,
///   `correlatedStepId`, optional `displayVariableValue`.
#[test]
fn test_origin_chain_vm_renders_cross_process_spans() {
    let pair_index = PairIndex::build(&[fe_recv_marker(), be_send_marker()]);
    let recv_hop = make_hop("payload", 12, "frontend/app.js", 3);
    let parent_hop = make_hop("balance", 14, "frontend/app.js", 4);
    let chain = OriginChain {
        query_variable: "balance".to_string(),
        query_step_id: 14,
        hops: vec![parent_hop, recv_hop],
        terminator: Terminator::new(TerminatorKind::RecordingStart),
        truncated: false,
        continuation_token: None,
        metrics: OriginMetrics::default(),
        cross_process_spans: Vec::new(),
        confidence: 0.9,
    };

    let identity = TraceIdentity::new("rec-fe", "frontend");
    let mut resolver = |_: &str, _: i64, _: &str| -> Option<SiblingContinuation> {
        Some(SiblingContinuation {
            sibling_identity: TraceIdentity::new("rec-be", "backend"),
            sibling_hops: vec![make_hop("db_row.balance", 6, "backend/server.py", 5)],
            sibling_terminator: Terminator::new(TerminatorKind::Computational),
            sibling_truncated: false,
        })
    };
    let (chain, _outcome) =
        apply_cross_process_clause(chain, &identity, &pair_index, &mut resolver as SiblingChainResolver);

    // Serialise to the canonical wire shape the Nim ViewModel reads.
    let json = serde_json::to_value(&chain).expect("serialise OriginChain");

    // Field: crossProcessSpans is an array with two entries.
    let spans = json["crossProcessSpans"]
        .as_array()
        .expect("crossProcessSpans is an array");
    assert_eq!(spans.len(), 2, "two spans expected; got {:?}", spans);
    assert_eq!(spans[0]["recordingId"], "rec-fe");
    assert_eq!(spans[0]["role"], "frontend");
    assert_eq!(spans[0]["firstHopIndex"], 0);
    assert_eq!(spans[0]["lastHopIndex"], 1);
    assert_eq!(spans[1]["recordingId"], "rec-be");
    assert_eq!(spans[1]["role"], "backend");
    assert_eq!(spans[1]["firstHopIndex"], 2);
    assert_eq!(spans[1]["lastHopIndex"], 2);

    // Field: hops[1].correlationTransition carries the boundary-
    // crossing descriptor.
    let hops = json["hops"].as_array().expect("hops is an array");
    let tx = hops[1]["correlationTransition"]
        .as_object()
        .expect("boundary hop has correlationTransition");
    assert_eq!(tx["boundaryId"], "balance-request");
    assert_eq!(tx["matchKeyValue"], "user-42");
    assert_eq!(tx["correlatedRecordingId"], "rec-be");
    assert_eq!(tx["correlatedStepId"], 6);
    assert_eq!(tx["direction"], "recv");
    // Display value is exposed so the renderer can show a
    // truncated label without a second round-trip.
    assert_eq!(tx["displayVariableValue"], "user-42");
}
