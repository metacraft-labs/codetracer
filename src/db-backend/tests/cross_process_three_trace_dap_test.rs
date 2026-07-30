//! Cross-process origin: the three-recording end-to-end contract.
//!
//! This is the headless-DAP layer of the cross-process E2E design
//! (`codetracer-specs/GUI/Test-Scenarios/Cross-Process-Origin-E2E-Test-Design.md`
//! §5.1) driven against **real recordings**.
//!
//! # What "real" means here, and why it matters
//!
//! Everything below the test is production code:
//!
//! * the three `.ct` containers are written by the actual recorders
//!   (`regenerate.sh` — see the fixture's README), not hand-authored;
//! * the session is loaded through the production `session.toml` loader
//!   by launching `db-backend` exactly the way `ct replay` does;
//! * the correlation index is derived by `SessionHandler::pair_index()`
//!   from marker events the recorders emitted;
//! * the chain is computed by the production `ct/originChain` dispatcher.
//!
//! The test supplies **no** pair index, **no** sibling hops, and **no**
//! expected chain to the code under test. That is the whole point: an
//! earlier version of this test hand-built the correlation index and the
//! sibling continuations and fed them to the composer, which meant it
//! passed while the feature was entirely unreachable from the product —
//! nothing outside the test ever constructed a `CrossProcessExtension`.
//! A cross-process test that supplies its own correlations is testing
//! its own fixtures.
//!
//! # The scenario
//!
//! ```text
//! frontend/app.js     userId = 42, amount = 100
//!      |                   JS -> WASM realm boundary
//!      v
//! wasm-src/lib.rs     compute_balance(42, 100) -> 620
//!      |                   HTTP boundary
//!      v
//! backend/server.js   balance = payload.balance
//! ```
//!
//! Querying the origin of the server's `balance` must walk back across
//! both boundaries, producing one `CrossProcessSpan` per recording.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

mod test_harness;

use std::path::PathBuf;
use std::time::Duration;

use db_backend::dap::DapMessage;
use db_backend::session_manifest::{ROLE_BACKEND, ROLE_FRONTEND_JS, ROLE_FRONTEND_WASM};
use db_backend::task::{CtOriginChainArguments, OriginChain};
use test_harness::DapStdioTestClient;

/// Fixture root, resolved against the crate manifest so the test does
/// not depend on the caller's working directory.
fn fixture_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/cross_process/account-balance-with-wasm")
}

/// Report the first missing piece of the fixture, if any.
///
/// The recordings are committed, so a missing one means the checkout is
/// incomplete rather than the environment being under-provisioned — the
/// caller turns this into a hard failure, not a skip. Silently skipping
/// here is what let the previous generation of this test report success
/// for months without ever loading a trace.
fn missing_fixture_piece() -> Option<String> {
    let root = fixture_root();
    for name in ["frontend.ct", "frontend-wasm.ct", "backend.ct", "session.toml"] {
        let candidate = root.join(name);
        if !candidate.exists() {
            return Some(format!(
                "{} is missing — run {}/regenerate.sh (see that directory's README.md)",
                candidate.display(),
                root.display()
            ));
        }
    }
    None
}

/// Issue `ct/originChain` for `variable_name` at the current position.
fn request_origin_chain(
    client: &mut DapStdioTestClient,
    variable_name: &str,
    step_id: i64,
    thread_id: i64,
) -> OriginChain {
    let args = CtOriginChainArguments {
        variable_name: variable_name.to_string(),
        variable_path: Vec::new(),
        frame_id: -1,
        step_id,
        thread_id,
        max_hops: 32,
        lazy: false,
        continuation_token: None,
        session_id: String::new(),
        classify_source: true,
    };
    let mut value = serde_json::to_value(&args).expect("serialise origin-chain args");
    // The session router keys off a camelCase `threadId` in the raw
    // request arguments; the typed field alone would leave the request
    // on slot 0 and silently answer about the wrong recording.
    if let Some(obj) = value.as_object_mut() {
        obj.insert("threadId".to_string(), serde_json::json!(thread_id));
    }
    let request = client.dap_client_mut().request("ct/originChain", value);
    client.send_message(&request).expect("send ct/originChain");
    let response = client
        .read_until_response_msg("ct/originChain", Duration::from_secs(60))
        .expect("ct/originChain response");
    match response {
        DapMessage::Response(r) => {
            assert!(
                r.success,
                "ct/originChain failed: {:?} body={}",
                r.message,
                serde_json::to_string(&r.body).unwrap_or_default()
            );
            serde_json::from_value(r.body).expect("decode OriginChain")
        }
        other => panic!("expected a response to ct/originChain, got {other:?}"),
    }
}

/// Ask the session for its process list.
fn list_processes(client: &mut DapStdioTestClient) -> Vec<serde_json::Value> {
    let request = client
        .dap_client_mut()
        .request("ct/listProcesses", serde_json::json!({}));
    client.send_message(&request).expect("send ct/listProcesses");
    let response = client
        .read_until_response_msg("ct/listProcesses", Duration::from_secs(30))
        .expect("ct/listProcesses response");
    match response {
        DapMessage::Response(r) => {
            assert!(r.success, "ct/listProcesses failed: {:?}", r.message);
            r.body
                .get("processes")
                .and_then(|p| p.as_array())
                .cloned()
                .unwrap_or_default()
        }
        other => panic!("expected a response, got {other:?}"),
    }
}

/// The composed thread id of the recording holding `role`.
fn thread_id_for_role(entries: &[serde_json::Value], role: &str) -> i64 {
    entries
        .iter()
        .find(|e| e.get("role").and_then(|r| r.as_str()) == Some(role))
        .and_then(|e| e.get("threadIds"))
        .and_then(|t| t.as_array())
        .and_then(|t| t.first())
        .and_then(|t| t.as_i64())
        .unwrap_or_else(|| panic!("no thread id advertised for role `{role}`"))
}

/// The three recordings load as one session and advertise their roles.
///
/// This is the precondition for everything else: without a session the
/// origin dispatcher never consults sibling traces at all.
#[test]
fn three_recordings_load_as_one_session_with_canonical_roles() {
    if let Some(missing) = missing_fixture_piece() {
        panic!("fixture incomplete: {missing}");
    }
    let manifest = fixture_root().join("session.toml");

    let mut client = DapStdioTestClient::start().expect("start db-backend");
    client
        .initialize_and_launch_session(&manifest)
        .expect("launch the three-trace session");

    let entries = list_processes(&mut client);

    let roles: Vec<String> = entries
        .iter()
        .filter_map(|e| e.get("role").and_then(|r| r.as_str()).map(str::to_string))
        .collect();
    assert_eq!(
        roles,
        vec![
            ROLE_FRONTEND_JS.to_string(),
            ROLE_FRONTEND_WASM.to_string(),
            ROLE_BACKEND.to_string()
        ],
        "the session must surface all three recordings in manifest order; got {roles:?}"
    );
}

/// M41 — the GUI launches a session by **folder**, not by manifest path.
///
/// `ct host` registers a session in the recording index with the
/// manifest's *directory* as the recording's `output_folder`, and the
/// frontend's DAP launch sends that folder verbatim as `traceFolder`
/// (`src/frontend/middleware.nim`). Nothing in that path ever names
/// `session.toml`.
///
/// So the folder spelling has to load the same session the manifest
/// spelling loads. The failure mode this pins is specifically *not* a
/// crash: before M41 the launch auto-detected a single trace file inside
/// the folder, which would have opened one arbitrary member and shown
/// the user a third of their program with no error at all.
#[test]
fn a_session_folder_launches_as_the_whole_session() {
    if let Some(missing) = missing_fixture_piece() {
        panic!("fixture incomplete: {missing}");
    }
    let folder = fixture_root();

    let mut client = DapStdioTestClient::start().expect("start db-backend");
    client
        .initialize_and_launch_session(&folder)
        .expect("launch the session by folder");

    let entries = list_processes(&mut client);
    let roles: Vec<String> = entries
        .iter()
        .filter_map(|e| e.get("role").and_then(|r| r.as_str()).map(str::to_string))
        .collect();
    assert_eq!(
        roles,
        vec![
            ROLE_FRONTEND_JS.to_string(),
            ROLE_FRONTEND_WASM.to_string(),
            ROLE_BACKEND.to_string()
        ],
        "launching the session FOLDER must load all three recordings, not one member; got {roles:?}"
    );
}

// Diagnosing a failure of the test below:
//
// If the origin chain stops inside the server recording, the usual
// cause is that a boundary did not pair. `ct print` shows each
// recording's declared crossings side by side:
//
//     ct print --filter markers frontend.ct
//     ct print --filter markers frontend-wasm.ct
//     ct print --filter markers backend.ct/server.ct
//
// The keys must match across recordings and the directions must be
// opposite. See the fixture's README for the expected output.

/// The north star: a value in the server recording traces back across
/// two process boundaries to the browser code that produced it.
#[test]
fn origin_of_the_server_balance_reaches_the_browser_recordings() {
    if let Some(missing) = missing_fixture_piece() {
        panic!("fixture incomplete: {missing}");
    }
    let root = fixture_root();
    let manifest = root.join("session.toml");
    let server_source = root.join("backend/server.js");

    let mut client = DapStdioTestClient::start().expect("start db-backend");
    client
        .initialize_and_launch_session(&manifest)
        .expect("launch the three-trace session");

    // Stop where the incoming value is bound. The line is the
    // `const balance = payload.balance;` statement in the handler;
    // resolved from the source rather than hard-coded so an edit to the
    // demo does not silently retarget the query.
    let source = std::fs::read_to_string(&server_source).expect("read the demo server source");
    let line = source
        .lines()
        .position(|l| l.contains("const balance = payload.balance"))
        .map(|idx| idx as u32 + 1)
        .expect("the demo server must bind `balance` from the request payload");

    let entries = list_processes(&mut client);
    let backend_thread = thread_id_for_role(&entries, ROLE_BACKEND);

    client
        .set_breakpoint_on_thread(&server_source, line, backend_thread)
        .expect("set a breakpoint in the server recording");
    let location = client
        .continue_to_breakpoint_on_thread(backend_thread)
        .expect("run to the balance binding");

    let chain = request_origin_chain(&mut client, "balance", location.rr_ticks.0, backend_thread);

    // The chain must leave the server recording. One span means the walk
    // never crossed a boundary — the single-trace behaviour.
    let span_roles: Vec<&str> = chain.cross_process_spans.iter().map(|s| s.role.as_str()).collect();
    assert!(
        chain.cross_process_spans.len() >= 2,
        "the chain must cross at least one process boundary; spans={span_roles:?}, \
         hops={:?}",
        chain
            .hops
            .iter()
            .map(|h| {
                format!(
                    "{}:{} @step {}",
                    h.location.path.rsplit('/').next().unwrap_or(h.location.path.as_str()),
                    h.location.line,
                    h.step_id
                )
            })
            .collect::<Vec<_>>()
    );
    assert_eq!(
        span_roles.first().copied(),
        Some(ROLE_BACKEND),
        "the walk starts in the recording the query targeted; spans={span_roles:?}"
    );
    assert!(
        span_roles.contains(&ROLE_FRONTEND_JS),
        "the chain must reach the browser JavaScript recording; spans={span_roles:?}"
    );
    // The north star: both boundaries walked in one query, so the chain
    // spans all three recordings the session holds.
    assert!(
        span_roles.contains(&ROLE_FRONTEND_WASM),
        "the chain must continue across the realm boundary into the WebAssembly \
         recording; spans={span_roles:?}"
    );

    // Every boundary-crossing hop must describe the crossing, otherwise
    // the UI has no breadcrumb to render and the user sees an unexplained
    // jump between files.
    let transitions = chain
        .hops
        .iter()
        .filter_map(|h| h.correlation_transition.as_ref())
        .count();
    assert!(
        transitions >= 1,
        "at least one hop must carry a correlationTransition descriptor"
    );
    for hop in &chain.hops {
        if let Some(tx) = hop.correlation_transition.as_ref() {
            assert!(
                !tx.boundary_id.is_empty(),
                "correlationTransition.boundaryId must be set"
            );
            assert!(
                !tx.correlated_recording_id.is_empty(),
                "correlationTransition.correlatedRecordingId must be set"
            );
        }
    }

    // The chain should land in the demo's browser source, which is the
    // user-visible payoff: a value observed on the server explained by
    // the front-end expression that produced it.
    let paths: Vec<&str> = chain.hops.iter().map(|h| h.location.path.as_str()).collect();
    assert!(
        paths.iter().any(|p| p.ends_with("app.js")),
        "the chain must include a hop in the browser source; paths={paths:?}"
    );
    // And into the WebAssembly module's own source. This is reachable
    // because the instrumenter records the values that cross the
    // module's host boundary — the arguments of every exported call and
    // the result it returns — and attributes them to a source location
    // read out of DWARF. The demo module computes entirely in locals
    // and stores nothing, which is the point: under the withdrawn
    // interior model (spec §§ 2, 11) it would have recorded no values
    // at all.
    assert!(
        paths.iter().any(|p| p.ends_with("lib.rs")),
        "the chain must reach the WebAssembly source; paths={paths:?}"
    );

    // The WASM span must own real hops rather than being an empty
    // placeholder — the difference between "the value came from that
    // module" and "here is where inside it".
    let wasm_span = chain
        .cross_process_spans
        .iter()
        .find(|s| s.role == ROLE_FRONTEND_WASM)
        .expect("a frontend-wasm span");
    assert!(
        (wasm_span.first_hop_index as usize) < chain.hops.len(),
        "the WebAssembly span must index real hops, not be a placeholder; \
         span={:?}..{:?}, hops={}",
        wasm_span.first_hop_index,
        wasm_span.last_hop_index,
        chain.hops.len()
    );
}
