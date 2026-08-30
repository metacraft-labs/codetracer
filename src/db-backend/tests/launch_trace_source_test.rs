//! `launch` must answer honestly about trace sources it cannot open.
//!
//! The embed SDK's `TraceSource.toLaunchArgs`
//! (`src/frontend/viewmodel/sdk/trace_source.nim`) emits
//! `{"traceSource": {"kind": …}}` for every browser source kind, and plain
//! `{"traceFolder": …}` only for `local-folder`. `LaunchRequestArguments`
//! carries `#[serde(deny_unknown_fields)]`, so before `traceSource` was a
//! declared field those launches failed **as a parse error**:
//!
//!   * natively, `run_dap_server` only `error!`s an `Err` out of
//!     `handle_message` — the client gets no `launch` response at all and
//!     waits forever;
//!   * in the SDK, `unknown field \`traceSource\`` matches none of the §6.3
//!     classifier's patterns, so a precisely-known "this engine can't open
//!     that" landed in the catch-all `BackendError` bucket.
//!
//! These tests pin the honest behaviour: a named refusal, delivered as a
//! `launch` response, classifiable as "unsupported", listing the vocabulary.

use std::sync::mpsc::channel;

use db_backend::dap::{self, DapMessage, LaunchRequestArguments, ProtocolMessage, TRACE_SOURCE_KINDS};
use db_backend::dap_server::{Ctx, handle_message};
use serde_json::json;

fn launch(arguments: serde_json::Value) -> DapMessage {
    DapMessage::Request(dap::Request {
        base: ProtocolMessage {
            seq: 7,
            type_: "request".to_string(),
        },
        command: "launch".to_string(),
        arguments,
    })
}

/// Drive one `launch` through the protocol handler and return the responses.
fn responses_for(arguments: serde_json::Value) -> (Vec<dap::Response>, Ctx, Result<(), String>) {
    let (sender, receiver) = channel::<DapMessage>();
    let mut ctx = Ctx::default();
    let result = handle_message(&launch(arguments), sender, &mut ctx).map_err(|e| e.to_string());
    let mut out = Vec::new();
    while let Ok(msg) = receiver.try_recv() {
        if let DapMessage::Response(r) = msg {
            out.push(r);
        }
    }
    (out, ctx, result)
}

/// The four browser kinds the SDK emits must each be refused by name.
#[test]
fn every_browser_trace_source_kind_is_refused_by_name() {
    let cases = [
        (
            "http-range",
            json!({"kind": "http-range", "url": "https://example.test/t.ct"}),
        ),
        ("opfs", json!({"kind": "opfs", "path": "traces/t.ct"})),
        ("bytes", json!({"kind": "bytes", "byteLength": 1234})),
        ("custom", json!({"kind": "custom", "name": "block-source"})),
    ];
    for (kind, source) in cases {
        let (responses, ctx, result) = responses_for(json!({ "traceSource": source }));
        assert!(
            result.is_ok(),
            "{kind}: the refusal must be a response, not an Err — the native server \
             loop only logs an Err and the client then never hears back at all",
        );
        let response = responses
            .iter()
            .find(|r| r.command == "launch")
            .unwrap_or_else(|| panic!("{kind}: no launch response"));
        assert!(!response.success, "{kind}: must not report success");
        let message = response
            .message
            .clone()
            .unwrap_or_else(|| panic!("{kind}: refusal carries no message"));
        assert!(
            message.contains(kind),
            "{kind}: the refusal must name the kind, got: {message}",
        );
        assert!(
            message.to_lowercase().contains("unsupported"),
            "{kind}: the SDK's classifyBackendFailure keys on `unsupported` to reach \
             UnsupportedTraceKind; without it a precisely-known failure lands in the \
             catch-all bucket. Got: {message}",
        );
        assert!(
            ctx.launch_trace_folder.as_os_str().is_empty(),
            "{kind}: a refused launch must not leave a trace folder behind",
        );
        assert!(
            ctx.launch_request.is_none(),
            "{kind}: a refused launch must not be stored for `configurationDone` to replay",
        );
    }
}

/// An SDK that grows a sixth kind must still get a message naming it,
/// not serde's `unknown variant`.
#[test]
fn an_unrecognised_kind_is_named_too() {
    let (responses, _, result) = responses_for(json!({ "traceSource": { "kind": "indexeddb" } }));
    assert!(result.is_ok());
    let response = responses.iter().find(|r| r.command == "launch").expect("response");
    assert!(!response.success);
    let message = response.message.clone().expect("message");
    assert!(message.contains("indexeddb"), "got: {message}");
    for kind in TRACE_SOURCE_KINDS {
        assert!(
            message.contains(kind),
            "the refusal must list the known vocabulary; `{kind}` missing from: {message}",
        );
    }
}

/// The one kind that works must keep working, so the refusal cannot be
/// "fixed" by refusing everything.
#[test]
fn a_local_folder_launch_is_still_accepted() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("trace.json"), "[]").unwrap();
    let (responses, ctx, result) = responses_for(json!({ "traceFolder": dir.path() }));
    assert!(result.is_ok());
    let response = responses.iter().find(|r| r.command == "launch").expect("response");
    assert!(response.success, "a local-folder launch must succeed");
    assert_eq!(ctx.launch_trace_folder, dir.path());
    assert!(ctx.launch_request.is_some());
}

/// `traceSource` must not defeat an accompanying `traceFolder`: the SDK
/// sends one or the other, but a client that sends both is asking for the
/// folder it named.
#[test]
fn a_trace_folder_wins_over_a_trace_source() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("trace.json"), "[]").unwrap();
    let (responses, ctx, _) = responses_for(json!({
        "traceFolder": dir.path(),
        "traceSource": { "kind": "http-range", "url": "https://example.test/t.ct" },
    }));
    let response = responses.iter().find(|r| r.command == "launch").expect("response");
    assert!(response.success);
    assert_eq!(ctx.launch_trace_folder, dir.path());
}

/// The wire shapes the SDK actually emits must parse. This is the half that
/// `deny_unknown_fields` used to reject.
#[test]
fn the_sdk_wire_shapes_deserialize() {
    for payload in [
        json!({"traceSource": {"kind": "http-range", "url": "https://example.test/t.ct"}}),
        json!({"traceSource": {"kind": "opfs", "path": "traces/t.ct"}}),
        json!({"traceSource": {"kind": "bytes", "byteLength": 42}}),
        json!({"traceSource": {"kind": "custom", "name": ""}}),
        json!({"traceFolder": "/tmp/trace"}),
    ] {
        let parsed: Result<LaunchRequestArguments, _> = serde_json::from_value(payload.clone());
        assert!(
            parsed.is_ok(),
            "the SDK emits {payload}; the engine must parse it to refuse it by name \
             instead of dying on `unknown field`. Got: {:?}",
            parsed.err(),
        );
    }
}

/// `deny_unknown_fields` is load-bearing and must stay: it is what turns the
/// *next* silent drift into a visible parse error rather than an ignored key.
#[test]
fn unknown_launch_fields_are_still_rejected() {
    let parsed: Result<LaunchRequestArguments, _> =
        serde_json::from_value(json!({"traceFolder": "/tmp/t", "someFutureField": 1}));
    assert!(
        parsed.is_err(),
        "LaunchRequestArguments must keep `deny_unknown_fields`; without it an \
         unrecognised launch argument is silently ignored",
    );
}

/// The vocabulary must match the SDK's `TraceSourceKind` exactly. The Nim
/// side asserts the same list against its own enum, so a kind added on one
/// side without the other fails here or there.
#[test]
fn the_kind_vocabulary_is_exactly_the_sdk_s() {
    assert_eq!(
        TRACE_SOURCE_KINDS,
        &["local-folder", "http-range", "opfs", "bytes", "custom"],
        "these strings are the wire contract with `TraceSourceKind` in \
         src/frontend/viewmodel/sdk/trace_source.nim",
    );
}
