//! M29 §5.2 — integration test for the `ct/listProcesses` DAP event
//! dispatched at session-load.
//!
//! Spec reference: ~Value-Origin-Tracking.milestones.org~ § M29 §5.2
//! ("VS Code extension parity ... plumbing the new ~ct/listProcesses~
//! event into the existing TypeScript handlers") + the Cross-Tracer
//! Origin Test campaign (TCT-M1) which calls out the event-dispatch
//! as the missing piece between the M24 ~SessionHandler::list_processes~
//! response builder and the renderer's process tree.
//!
//! ## What this test pins
//!
//! 1. Loading a `session.toml` with three `[[trace]]` entries
//!    (frontend-js, frontend-wasm, backend) results in **exactly one**
//!    `ct/listProcesses` DAP event landing on the wire (the
//!    SessionHandler-owned channel `Sender<DapMessage>`).
//! 2. The event carries `type == "event"` (per the DAP protocol
//!    envelope shape) + `event == "ct/listProcesses"` + a `body`
//!    whose `processes` array has one entry per `[[trace]]` row, in
//!    manifest order.
//! 3. Each row carries the canonical wire fields the frontend
//!    consumes: `recordingId`, `role`, `displayName`, plus the
//!    multi-trace routing fields (`defaultThreadPrefix`,
//!    `threadCount`, `threadIds`).
//! 4. **Idempotence on re-load**: dispatching a second event after a
//!    fresh session (representing the "recording added" case) yields a
//!    second event whose payload is the complete updated snapshot
//!    — not a delta. The first event remains observable on the wire
//!    so any consumer that missed it can read it from the channel
//!    backlog; the contract is "every event is a total snapshot".

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use db_backend::dap::DapMessage;
use db_backend::dap_handler::Handler;
use db_backend::dap_server::dispatch_session_load_event;
use db_backend::db::Db;
use db_backend::recreator_session::RecreatorArgs;
use db_backend::session_handler::SessionHandler;
use db_backend::session_manifest::{RecordingId, SessionManifest, TraceEntry};
use db_backend::task::TraceKind;
use std::path::PathBuf;
use std::sync::mpsc;

fn make_handler(name: &str) -> Handler {
    let args = RecreatorArgs {
        name: name.to_string(),
        ..RecreatorArgs::default()
    };
    Handler::new(TraceKind::Materialized, args, Box::new(Db::new(&PathBuf::from(""))))
}

/// Synthetic session.toml content for the three-entry fixture used
/// throughout this test. Written to disk so the test exercises the
/// real `SessionManifest::load` parser (per the TCT-M1 requirement
/// "loads a synthetic session.toml with three entries"); the loaded
/// manifest is then handed to `SessionHandler::new` with synthetic
/// handlers because the trace bodies do not exist on disk and
/// loading them would require the full recorder pipeline.
fn three_trace_session_toml() -> &'static str {
    r#"
version = 1

[[trace]]
recording_id = "rec-frontend-js"
path = "frontend.ct"
role = "frontend-js"
default_thread_prefix = "fe-js"

[[trace]]
recording_id = "rec-frontend-wasm"
path = "wasm-module.ct"
role = "frontend-wasm"
default_thread_prefix = "fe-wasm"

[[trace]]
recording_id = "rec-backend"
path = "backend.ct"
role = "backend"
default_thread_prefix = "be"
"#
}

/// Two-trace session.toml used as the "before" state of the
/// idempotence test — the "after" state rewrites the manifest with
/// the three-entry fixture (a third recording added).
fn two_trace_session_toml() -> &'static str {
    r#"
version = 1

[[trace]]
recording_id = "rec-frontend-js"
path = "frontend.ct"
role = "frontend-js"
default_thread_prefix = "fe-js"

[[trace]]
recording_id = "rec-backend"
path = "backend.ct"
role = "backend"
default_thread_prefix = "be"
"#
}

/// Build a SessionHandler from on-disk session.toml + one synthetic
/// Handler per entry. The synthetic handlers are sufficient for the
/// event-emission test because the event payload is derived solely
/// from the manifest + the `SessionHandler::list_processes` projection
/// (which under the M24 `inner_threads_for_slot` fallback synthesises
/// `[(1, "<thread 1>")]` per trace and does not touch the handler's
/// trace contents).
fn load_session_from_disk(manifest_path: &std::path::Path, trace_count: usize) -> SessionHandler {
    let manifest = SessionManifest::load(manifest_path).expect("load synthetic session.toml");
    assert_eq!(manifest.traces.len(), trace_count, "manifest entry count");
    let handlers: Vec<Handler> = manifest
        .traces
        .iter()
        .map(|entry| make_handler(&format!("handler-{}", entry.recording_id.0)))
        .collect();
    SessionHandler::new(manifest, handlers).expect("build SessionHandler")
}

/// Drain every message currently buffered on the receiver. Used to
/// snapshot what the dispatch helper enqueued without blocking on
/// future messages.
fn drain_messages(rx: &mpsc::Receiver<DapMessage>) -> Vec<DapMessage> {
    let mut out = Vec::new();
    while let Ok(msg) = rx.try_recv() {
        out.push(msg);
    }
    out
}

/// Extract the `(event_name, body)` pair from a `DapMessage`,
/// panicking when the message is not an Event. Keeps the per-test
/// assertions readable.
fn expect_event(msg: &DapMessage) -> (&str, &serde_json::Value) {
    match msg {
        DapMessage::Event(ev) => {
            // Per the DAP protocol envelope, every event carries
            // `type: "event"` — pin it so a regression in the
            // `ProtocolMessage` shape surfaces here.
            assert_eq!(ev.base.type_, "event", "DAP event envelope type field");
            (ev.event.as_str(), &ev.body)
        }
        other => panic!("expected DapMessage::Event, got {other:?}"),
    }
}

/// M29 §5.2 — primary deliverable: the `ct/listProcesses` event lands
/// on the DAP wire after a session.toml with three entries is loaded.
#[test]
fn dap_server_emits_list_processes_on_session_load() {
    // Stage 1 — write a synthetic session.toml to disk.
    let tmp = tempfile::tempdir().expect("tempdir");
    let manifest_path = tmp.path().join("session.toml");
    std::fs::write(&manifest_path, three_trace_session_toml()).expect("write session.toml");

    // Stage 2 — build the SessionHandler from the real on-disk
    // manifest plus synthetic handlers.
    let session = load_session_from_disk(&manifest_path, 3);
    assert_eq!(session.trace_count(), 3);

    // Stage 3 — set up the DAP wire (a `Sender<DapMessage>` channel),
    // dispatch the session-load event, and snapshot what landed.
    let (tx, rx) = mpsc::channel::<DapMessage>();
    dispatch_session_load_event(&session, &tx);
    let messages = drain_messages(&rx);

    assert_eq!(
        messages.len(),
        1,
        "exactly one ct/listProcesses event expected, got {}",
        messages.len()
    );
    let (event_name, body) = expect_event(&messages[0]);
    assert_eq!(event_name, "ct/listProcesses", "event name");

    let processes = body["processes"].as_array().expect("processes is an array");
    assert_eq!(processes.len(), 3, "three process entries expected");

    // Pin the three-row payload in manifest order. Each row carries
    // the recording id + role + display-name + routing metadata.
    assert_eq!(processes[0]["recordingId"], "rec-frontend-js");
    assert_eq!(processes[0]["role"], "frontend-js");
    assert_eq!(processes[0]["displayName"], "frontend.ct");
    assert_eq!(processes[0]["defaultThreadPrefix"], "fe-js");
    assert_eq!(processes[0]["threadCount"], 1);

    assert_eq!(processes[1]["recordingId"], "rec-frontend-wasm");
    assert_eq!(processes[1]["role"], "frontend-wasm");
    assert_eq!(processes[1]["displayName"], "wasm-module.ct");
    assert_eq!(processes[1]["defaultThreadPrefix"], "fe-wasm");
    assert_eq!(processes[1]["threadCount"], 1);

    assert_eq!(processes[2]["recordingId"], "rec-backend");
    assert_eq!(processes[2]["role"], "backend");
    assert_eq!(processes[2]["displayName"], "backend.ct");
    assert_eq!(processes[2]["defaultThreadPrefix"], "be");
    assert_eq!(processes[2]["threadCount"], 1);

    // threadIds are composed per the M24 routing scheme (slot << 24 | inner).
    let thread_ids: Vec<i64> = processes[0]["threadIds"]
        .as_array()
        .expect("threadIds array")
        .iter()
        .map(|v| v.as_i64().expect("i64 thread id"))
        .collect();
    assert_eq!(thread_ids, vec![1], "slot 0 / inner 1 → composed id 1");
    let thread_ids: Vec<i64> = processes[2]["threadIds"]
        .as_array()
        .expect("threadIds array")
        .iter()
        .map(|v| v.as_i64().expect("i64 thread id"))
        .collect();
    assert_eq!(
        thread_ids,
        vec![(2_i64) << 24 | 1],
        "slot 2 / inner 1 → composed id (2<<24)|1"
    );
}

/// M29 §5.2 — idempotence: re-dispatching after a recording is added
/// produces a fresh full snapshot, not a delta. Both events remain on
/// the wire so a late consumer can replay the channel.
///
/// The session.toml format caps total trace count at the cross-tracer
/// audit's three-process ceiling (TCT-M1) — so we exercise the "add a
/// recording" case by starting with two entries and re-loading with
/// three after a new `[[trace]]` row is added.
#[test]
fn dap_server_emits_idempotent_list_processes_on_session_reload() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let manifest_path = tmp.path().join("session.toml");
    std::fs::write(&manifest_path, two_trace_session_toml()).expect("write session.toml");

    let (tx, rx) = mpsc::channel::<DapMessage>();

    // First load — dispatch the initial snapshot.
    let session_v1 = load_session_from_disk(&manifest_path, 2);
    dispatch_session_load_event(&session_v1, &tx);

    // Simulate "recording added": rewrite the session.toml with the
    // three-entry fixture (the frontend-wasm trace is the new one).
    // In production this corresponds to a fresh `launch` request
    // landing in the dap_server worker loop with an updated
    // session.toml.
    std::fs::write(&manifest_path, three_trace_session_toml()).expect("rewrite session.toml");

    let session_v2 = load_session_from_disk(&manifest_path, 3);
    dispatch_session_load_event(&session_v2, &tx);

    // Both events landed on the wire — the contract is "every event
    // is a total snapshot"; a late consumer replays both.
    let messages = drain_messages(&rx);
    assert_eq!(
        messages.len(),
        2,
        "two ct/listProcesses events expected (initial + reload), got {}",
        messages.len()
    );

    // First snapshot — two entries.
    let (name1, body1) = expect_event(&messages[0]);
    assert_eq!(name1, "ct/listProcesses");
    let processes_v1 = body1["processes"].as_array().expect("v1 processes");
    assert_eq!(processes_v1.len(), 2, "v1 snapshot has two entries");
    assert_eq!(processes_v1[0]["recordingId"], "rec-frontend-js");
    assert_eq!(processes_v1[1]["recordingId"], "rec-backend");

    // Second snapshot — full three entries, including the newly added
    // frontend-wasm trace. Crucially, the second event is a complete
    // snapshot (not a delta listing only the new entry).
    let (name2, body2) = expect_event(&messages[1]);
    assert_eq!(name2, "ct/listProcesses");
    let processes_v2 = body2["processes"].as_array().expect("v2 processes");
    assert_eq!(processes_v2.len(), 3, "v2 snapshot is a complete re-emit, not a delta");
    assert_eq!(processes_v2[0]["recordingId"], "rec-frontend-js");
    assert_eq!(processes_v2[1]["recordingId"], "rec-frontend-wasm");
    assert_eq!(processes_v2[1]["role"], "frontend-wasm");
    assert_eq!(processes_v2[1]["displayName"], "wasm-module.ct");
    assert_eq!(processes_v2[2]["recordingId"], "rec-backend");
}

/// Defensive: the single-trace backwards-compat path also emits an
/// event with one entry. Pinning this guards against accidentally
/// confining the dispatch path to the multi-trace branch only.
#[test]
fn dap_server_emits_list_processes_for_single_trace_session() {
    let trace_path = PathBuf::from("/tmp/single-trace-example.ct");
    let manifest = SessionManifest::single_trace(trace_path.clone());
    let recording_id = manifest.traces[0].recording_id.0.clone();
    let session = SessionHandler::new(manifest, vec![make_handler("single")]).expect("session");

    let (tx, rx) = mpsc::channel::<DapMessage>();
    dispatch_session_load_event(&session, &tx);
    let messages = drain_messages(&rx);

    assert_eq!(messages.len(), 1);
    let (event_name, body) = expect_event(&messages[0]);
    assert_eq!(event_name, "ct/listProcesses");
    let processes = body["processes"].as_array().expect("processes array");
    assert_eq!(processes.len(), 1);
    // The synthetic single-trace manifest assigns role "main" — pinning
    // it here documents the backwards-compat surface so a future M24
    // refactor that changes the role string fails this test instead of
    // silently changing the single-trace event payload.
    assert_eq!(processes[0]["role"], "main");
    assert_eq!(processes[0]["recordingId"], recording_id);
    assert_eq!(processes[0]["displayName"], "single-trace-example.ct");
    assert_eq!(processes[0]["defaultThreadPrefix"], "");
}

/// Defensive: when the manifest's `path` is empty (live-recording
/// case where the recorder has not yet finalised the trace file), the
/// `displayName` falls back to the recording id so the wire shape
/// always carries a non-empty label.
#[test]
fn dap_server_list_processes_event_falls_back_to_recording_id_when_path_empty() {
    let manifest = SessionManifest {
        version: 1,
        traces: vec![TraceEntry {
            recording_id: RecordingId("rec-live-42".to_string()),
            path: PathBuf::from(""),
            role: "main".to_string(),
            default_thread_prefix: String::new(),
        }],
        correlation: Default::default(),
        base_dir: PathBuf::from("."),
    };
    let session = SessionHandler::new(manifest, vec![make_handler("live")]).expect("session");

    let (tx, rx) = mpsc::channel::<DapMessage>();
    dispatch_session_load_event(&session, &tx);
    let messages = drain_messages(&rx);

    assert_eq!(messages.len(), 1);
    let (_, body) = expect_event(&messages[0]);
    let processes = body["processes"].as_array().expect("processes");
    assert_eq!(processes[0]["displayName"], "rec-live-42",);
}

// ---------------------------------------------------------------------------
// M29 §5.2 / TCT-M4 — three-trace session manifest test.
//
// Pins the `ct/listProcesses` event payload for the canonical
// `frontend-js → frontend-wasm → backend` shape the TCT-M1/TCT-M4
// closure plan defines (~Cross-Tracer-Origin-Test.audit.md~ §§ TCT-M1,
// TCT-M4). Preferred input is the `account-balance-with-wasm` fixture's
// `session.toml.template` once TCT-M4 lands the on-disk skeleton; until
// then the test materialises a synthetic equivalent with the same
// three canonical role tokens so the event-dispatch contract is
// regression-protected today.
// ---------------------------------------------------------------------------

/// Locate the TCT-M4 `account-balance-with-wasm/session.toml.template`
/// relative to this test crate. Returns `None` when the fixture is not
/// yet materialised on disk so the caller can fall back cleanly to the
/// synthetic shape (per the M5 SKIP discipline — never silently
/// downgrade an assertion).
fn locate_wasm_fixture_template() -> Option<PathBuf> {
    let candidate = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/cross_process/account-balance-with-wasm/session.toml.template");
    if candidate.is_file() { Some(candidate) } else { None }
}

/// Materialise the fixture template by substituting the three
/// `{{*_recording_id}}` placeholders with stable synthetic ids. The
/// `regenerate.sh` script would normally stamp UUIDv7 ids; the test
/// path uses fixed strings so the assertions can pin them.
fn materialise_wasm_fixture(template_path: &std::path::Path, dest: &std::path::Path) -> std::io::Result<()> {
    let text = std::fs::read_to_string(template_path)?;
    let rendered = text
        .replace("{{frontend_js_recording_id}}", "rec-fe-js-account-balance")
        .replace("{{frontend_wasm_recording_id}}", "rec-fe-wasm-account-balance")
        .replace("{{backend_recording_id}}", "rec-be-account-balance");
    std::fs::write(dest, rendered)
}

/// Synthetic three-trace session.toml matching the TCT-M4 fixture
/// shape — the canonical `frontend-js → frontend-wasm → backend` chain
/// per `Cross-Tracer-Origin-Test.audit.md` §§ TCT-M1, TCT-M4. Used as
/// the fall-back when the on-disk fixture has not been materialised
/// yet so the event-dispatch contract is regression-protected today.
/// Field values mirror the fixture's `session.toml.template` so the
/// fixture-path + synthetic-path assertions share a single contract.
fn wasm_three_trace_session_toml() -> &'static str {
    r#"
version = 1

[[trace]]
recording_id = "rec-fe-js-account-balance"
path = "./frontend.ct"
role = "frontend-js"
default_thread_prefix = "fe"

[[trace]]
recording_id = "rec-fe-wasm-account-balance"
path = "./frontend-wasm.ct"
role = "frontend-wasm"
default_thread_prefix = "wasm"

[[trace]]
recording_id = "rec-be-account-balance"
path = "./backend.ct"
role = "backend"
default_thread_prefix = "be"

[correlation]
correlation_index_mode = "eager"
"#
}

/// M29 §5.2 / TCT-M4 — the `ct/listProcesses` event dispatched at
/// session-load for a three-trace `account-balance-with-wasm` manifest
/// carries exactly three entries in the canonical
/// `frontend-js → frontend-wasm → backend` order with the wire-shape
/// fields the renderer's process tree consumes.
///
/// Preferred input is the TCT-M4 fixture's `session.toml.template`;
/// when absent, the test materialises an equivalent synthetic shape so
/// the dispatch contract is pinned today without blocking on the
/// recorder-driven fixture infrastructure (see M29 deferred-items
/// note in the milestone).
#[test]
fn dap_server_emits_list_processes_for_three_trace_wasm_fixture() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let manifest_path = tmp.path().join("session.toml");

    // Stage 1 — prefer the on-disk fixture template; fall back to the
    // synthetic equivalent when the fixture is not yet materialised.
    // The fall-back path is *not* a SKIP — the dispatch contract is
    // assertion-equivalent against the synthetic shape; the fixture
    // path simply exercises the on-disk template substitution that
    // TCT-M4's `regenerate.sh` will eventually drive.
    match locate_wasm_fixture_template() {
        Some(template) => {
            materialise_wasm_fixture(&template, &manifest_path).expect("materialise wasm fixture");
        }
        None => {
            std::fs::write(&manifest_path, wasm_three_trace_session_toml()).expect("write synthetic session.toml");
        }
    }

    // Stage 2 — drive the production session-load path: real
    // `SessionManifest::load` parses the on-disk TOML, real
    // `SessionHandler::new` aggregates the synthetic per-trace handlers.
    let session = load_session_from_disk(&manifest_path, 3);
    assert_eq!(session.trace_count(), 3);

    // Stage 3 — dispatch the event the way `dap_server` does in
    // production; snapshot what landed on the wire.
    let (tx, rx) = mpsc::channel::<DapMessage>();
    dispatch_session_load_event(&session, &tx);
    let messages = drain_messages(&rx);

    // Exactly one event lands per session-load — the §5.2 contract.
    assert_eq!(messages.len(), 1, "exactly one ct/listProcesses event expected");
    let (event_name, body) = expect_event(&messages[0]);
    assert_eq!(event_name, "ct/listProcesses");

    let processes = body["processes"].as_array().expect("processes array");
    assert_eq!(processes.len(), 3, "three process entries expected");

    // Stage 4 — pin the canonical role ordering. The renderer process
    // tree walks `SessionHandler::list_processes` output in manifest
    // order, so `frontend-js → frontend-wasm → backend` is the
    // ordering the GUI displays per TCT-M1.
    let roles: Vec<&str> = processes
        .iter()
        .map(|p| p["role"].as_str().expect("role string"))
        .collect();
    assert_eq!(
        roles,
        vec!["frontend-js", "frontend-wasm", "backend"],
        "canonical role ordering"
    );

    // Stage 5 — pin each entry's wire-shape fields: `recordingId`,
    // `role`, `displayName`, `defaultThreadPrefix`, `threadCount`,
    // `threadIds`. The `threadIds` follow the M24 composition scheme
    // (`slot << 24 | inner`); slot 0/1/2 with inner thread 1 each.
    assert_eq!(processes[0]["recordingId"], "rec-fe-js-account-balance");
    assert_eq!(processes[0]["displayName"], "frontend.ct");
    assert_eq!(processes[0]["defaultThreadPrefix"], "fe");
    assert_eq!(processes[0]["threadCount"], 1);
    assert_eq!(processes[0]["threadIds"], serde_json::json!([1_i64]));

    assert_eq!(processes[1]["recordingId"], "rec-fe-wasm-account-balance");
    assert_eq!(processes[1]["displayName"], "frontend-wasm.ct");
    assert_eq!(processes[1]["defaultThreadPrefix"], "wasm");
    assert_eq!(processes[1]["threadCount"], 1);
    assert_eq!(processes[1]["threadIds"], serde_json::json!([(1_i64 << 24) | 1]));

    assert_eq!(processes[2]["recordingId"], "rec-be-account-balance");
    assert_eq!(processes[2]["displayName"], "backend.ct");
    assert_eq!(processes[2]["defaultThreadPrefix"], "be");
    assert_eq!(processes[2]["threadCount"], 1);
    assert_eq!(processes[2]["threadIds"], serde_json::json!([(2_i64 << 24) | 1]));
}
