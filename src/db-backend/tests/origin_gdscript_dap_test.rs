//! GDScript through the **standard viewmodel / DAP handler path** — the
//! same `Handler` DAP entry points (`next_dap`, `step_back_dap`,
//! `load_locals`, `origin_chain`) that the Python and Ruby materialized
//! recorders are driven through by `origin_python_dap_test.rs`,
//! `origin_ruby_dap_test.rs`, `dap_statement_step_over.rs`, and
//! `origin_viewmodel_test.rs`.
//!
//! # Why this file exists
//!
//! GDScript already has bespoke `verify_gdscript_*` tests that exercise
//! `MaterializedReplaySession::origin_chain_inferred` **directly** (a
//! lower-level API), passing an *explicit* sources root so the classifier
//! can read the recorded `.gd` text. Those tests prove the algorithm
//! works; they do NOT prove GDScript is reachable through the same
//! `Handler`-level DAP/viewmodel surface every other language uses. This
//! file closes that gap by driving the production `Handler` DAP methods —
//! constructed exactly the way `dap_server::setup` builds a materialized
//! handler from a `.ct` container — against the committed engine-recorded
//! fixture (`tests/fixtures/gdscript/gf_values/gdscript_trace.ct`).
//!
//! # No mocks
//!
//! No mocks. It opens the real committed `.ct` through the production
//! `CTFSTraceReader::open` + `Handler::construct_with_reader(
//! TraceKind::Materialized, …)` code path and issues real
//! `CtOriginChainArguments` / `CtLoadLocalsArguments` DAP requests,
//! decoding the wire responses the Nim ViewModel consumes.
//!
//! # No silent skip
//!
//! The fixture is committed, so the test always runs; a missing fixture
//! fails loudly (repository-integrity error, not an environment gap).
//!
//! # Findings (see the individual tests for the teeth)
//!
//! Driving GDScript through the standard DAP handler now shows GDScript is
//! a **first-class citizen on all three axes** through the same
//! viewmodel/DAP surface every other language uses:
//!
//! * **Time-travel (`next` / `stepBack`)** — WORKS. The DAP stepping
//!   runners advance and reverse the step cursor over the GDScript trace
//!   exactly as they do for Python/Ruby.
//! * **Locals (`ct/load-locals`)** — WORKS. The State-Pane viewmodel
//!   path returns the correct GDScript locals and values at each step
//!   (`i == 10` at line 35, `i == 15` at line 40, `factor == 30` inside
//!   `scale`).
//! * **Value-origin (`ct/originChain`)** — WORKS (§5.2, this change). The
//!   recorder stores a Godot virtual path (`res://gf_values.gd`) that never
//!   exists on disk, so the standalone `.ct` now BUNDLES each recorded
//!   `.gd`'s source TEXT (via the CTFS srcviews stream). At trace open
//!   `Handler::load_bundled_sources` extracts that bundle so
//!   `Handler::meta_dat_sources_root` points the value-origin classifier at
//!   the self-contained copy (spec §6.1), and
//!   `Handler::materialized_origin_chain` returns a REAL chain — no
//!   explicit sources-root hook, no on-disk project. See
//!   `test_gdscript_dap_value_origin_resolves_over_standard_dap_path`.
//!   Before this change it returned `TerminatorKind::UnknownSource` because
//!   `meta_dat_sources_root` derived solely from the vanished
//!   `reader.workdir()/meta_dat/sources`; the bundled-sources root now wins.
//!
//! Python/Ruby never hit this gap because they record real absolute on-disk
//! source paths that `ExprLoader::load_file` reads directly; GDScript's
//! `res://` paths require the bundle, which is what §5.2 adds.

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::mpsc;

use codetracer_trace_types::{StepId, ValueRecord};
use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::dap::{DapMessage, ProtocolMessage, Request};
use db_backend::dap_handler::Handler;
use db_backend::lang::Lang;
use db_backend::recreator_session::RecreatorArgs;
use db_backend::task::{
    CtLoadLocalsArguments, CtOriginChainArguments, DEFAULT_ORIGIN_MAX_HOPS, OriginChain, OriginKind, TerminatorKind,
    TraceKind,
};
use db_backend::trace_reader::TraceReader;
use serde_json::Value as JsonValue;

// ---------------------------------------------------------------------------
// Fixture + handler construction (mirrors `dap_server::setup` for a
// materialized `.ct` container).
// ---------------------------------------------------------------------------

fn fixture_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("gdscript")
        .join("gf_values")
}

fn fixture_ct() -> PathBuf {
    fixture_dir().join("gdscript_trace.ct")
}

/// Open the committed CTFS container through the production reader.
fn open_reader() -> Arc<dyn TraceReader> {
    let ct = fixture_ct();
    assert!(
        ct.is_file(),
        "GDScript fixture trace missing at {} — this test must NOT silently skip",
        ct.display()
    );
    Arc::new(CTFSTraceReader::open(&ct).unwrap_or_else(|e| panic!("CTFS open failed for {}: {}", ct.display(), e)))
}

/// Build the same materialized `Handler` `dap_server::setup` builds for a
/// `.ct` launch (minus the out-of-band origin-metadata decoder, which
/// `gf_values` does not carry — GF10 is not implemented).
fn build_handler(reader: Arc<dyn TraceReader>) -> Handler {
    let ct = fixture_ct();
    let mut handler = Handler::construct_with_reader(
        TraceKind::Materialized,
        RecreatorArgs::default(),
        Arc::clone(&reader),
        false,
    );
    handler.set_trace_folder(&ct);
    handler.load_source_views(&ct);
    // §5.2 — extract the sources the GDScript `.ct` bundled so the value-origin
    // classifier resolves `res://gf_values.gd` self-contained (no explicit
    // sources-root hook, no on-disk project). Mirrors `dap_server::setup`.
    handler.load_bundled_sources(&ct);
    handler.initialized = true;
    handler
}

/// First step whose 1-based source line equals `line`.
fn step_at_line(reader: &Arc<dyn TraceReader>, line: i64) -> StepId {
    for idx in 0..reader.step_count() {
        let sid = StepId(idx as i64);
        if let Some(step) = reader.step(sid)
            && step.line.0 == line
        {
            return sid;
        }
    }
    panic!("no step found at line {line}");
}

// ---------------------------------------------------------------------------
// DAP request/response plumbing.
// ---------------------------------------------------------------------------

fn make_request(command: &str, args: JsonValue) -> Request {
    Request {
        base: ProtocolMessage {
            seq: 1,
            type_: "request".to_string(),
        },
        command: command.to_string(),
        arguments: args,
    }
}

fn take_body(rx: &mpsc::Receiver<DapMessage>, command: &str) -> JsonValue {
    while let Ok(msg) = rx.try_recv() {
        if let DapMessage::Response(resp) = msg
            && resp.command == command
        {
            assert!(resp.success, "expected `{command}` to succeed, body={:?}", resp.body);
            return resp.body;
        }
    }
    panic!("no response on the channel for command `{command}`");
}

/// Jump the handler to `step` and read the GDScript locals visible there
/// through the real `ct/load-locals` DAP handler. Returns the decoded
/// `locals` array from the wire response.
fn load_locals_at(handler: &mut Handler, step: StepId) -> Vec<JsonValue> {
    handler.step_id = step;
    handler
        .replay
        .jump_to(step)
        .expect("jump_to must succeed on a materialized trace");
    let (tx, rx) = mpsc::channel::<DapMessage>();
    let args = CtLoadLocalsArguments {
        rr_ticks: step.0,
        count_budget: 1000,
        min_count_limit: 0,
        lang: Lang::GDScript,
        watch_expressions: Vec::new(),
        depth_limit: -1,
    };
    let req = make_request("ct/load-locals", serde_json::to_value(&args).unwrap());
    handler.load_locals(req, args, tx).expect("load_locals");
    let body = take_body(&rx, "ct/load-locals");
    body.get("locals")
        .and_then(JsonValue::as_array)
        .cloned()
        .expect("locals array")
}

/// The integer value of local `name` from a decoded `ct/load-locals`
/// response body (Int values serialize with the digits in `value.i`).
fn local_int(locals: &[JsonValue], name: &str) -> i64 {
    let local = locals
        .iter()
        .find(|l| l.get("expression").and_then(JsonValue::as_str) == Some(name))
        .unwrap_or_else(|| panic!("local `{name}` not present in {locals:?}"));
    local
        .get("value")
        .and_then(|v| v.get("i"))
        .and_then(JsonValue::as_str)
        .and_then(|s| s.parse::<i64>().ok())
        .unwrap_or_else(|| panic!("local `{name}` is not an Int: {local:?}"))
}

/// Issue `ct/originChain` through the real DAP handler and decode.
fn origin_chain(handler: &mut Handler, variable: &str, step: StepId) -> OriginChain {
    let (tx, rx) = mpsc::channel::<DapMessage>();
    let args = CtOriginChainArguments {
        variable_name: variable.to_string(),
        variable_path: Vec::new(),
        frame_id: -1,
        step_id: step.0,
        thread_id: 0,
        max_hops: DEFAULT_ORIGIN_MAX_HOPS,
        lazy: false,
        continuation_token: None,
        session_id: String::new(),
        classify_source: true,
    };
    let req = make_request("ct/originChain", serde_json::to_value(&args).unwrap());
    handler
        .origin_chain(req, args, tx)
        .expect("origin_chain must not surface a DAP error");
    let body = take_body(&rx, "ct/originChain");
    serde_json::from_value(body).expect("decode OriginChain")
}

// ---------------------------------------------------------------------------
// (1) TIME-TRAVEL — `next` / `stepBack` through the DAP handler.
// ---------------------------------------------------------------------------

/// The DAP forward (`next`) and reverse (`stepBack`) stepping runners
/// advance and reverse the step cursor over the GDScript trace — the same
/// `Handler::next_dap` / `Handler::step_back_dap` entry points the
/// Python/Ruby materialized traces use (`dap_statement_step_over.rs`).
#[test]
fn test_gdscript_dap_time_travel_step_forward_and_back() {
    let reader = open_reader();
    let mut handler = build_handler(Arc::clone(&reader));

    // Start at the `var i := 10` declaration (line 35) and confirm the
    // handler is positioned there.
    let start = step_at_line(&reader, 35);
    handler.step_id = start;
    handler.replay.jump_to(start).expect("jump_to line-35 step");
    assert_eq!(
        reader.step(handler.step_id).map(|s| s.line.0),
        Some(35),
        "handler must start on line 35"
    );

    // Forward `next` (line granularity) advances the step cursor.
    let (tx, rx) = mpsc::channel::<DapMessage>();
    handler
        .next_dap(make_request("next", serde_json::json!({ "threadId": 1 })), None, tx)
        .expect("dap next");
    while rx.try_recv().is_ok() {}
    let after_next = handler.step_id;
    assert!(
        after_next.0 > start.0,
        "forward `next` must advance the step id: {start:?} -> {after_next:?}"
    );

    // Reverse `stepBack` walks the cursor back toward the start.
    let (tx, rx) = mpsc::channel::<DapMessage>();
    handler
        .step_back_dap(make_request("stepBack", serde_json::json!({ "threadId": 1 })), None, tx)
        .expect("dap stepBack");
    while rx.try_recv().is_ok() {}
    let after_back = handler.step_id;
    assert!(
        after_back.0 < after_next.0,
        "reverse `stepBack` must move the step id backwards: {after_next:?} -> {after_back:?}"
    );

    // The reader agrees the jumped-to positions are coherent (path/line),
    // proving forward/back time-travel is not a no-op.
    let step = reader.step(handler.step_id).expect("landed step exists");
    assert_eq!(reader.path(step.path_id), Some("res://gf_values.gd"), "recorded path");
}

// ---------------------------------------------------------------------------
// (2) LOCALS — `ct/load-locals` through the DAP handler / ViewModel path.
// ---------------------------------------------------------------------------

/// The State-Pane viewmodel path (`ct/load-locals`) returns the correct
/// GDScript locals and values at each step — the same DAP surface the
/// Python/Ruby State Pane consumes (`origin_viewmodel_test.rs`).
#[test]
fn test_gdscript_dap_locals_visible_with_correct_values() {
    let reader = open_reader();
    let mut handler = build_handler(Arc::clone(&reader));

    // `var i := 10` (line 35) → i == 10.
    let locals_35 = load_locals_at(&mut handler, step_at_line(&reader, 35));
    assert_eq!(local_int(&locals_35, "i"), 10, "i at line 35 (ct/load-locals)");

    // `i = i + 5` (line 40) → i == 15.
    let locals_40 = load_locals_at(&mut handler, step_at_line(&reader, 40));
    assert_eq!(local_int(&locals_40, "i"), 15, "i at line 40 (ct/load-locals)");

    // Inside callee `scale` (line 31) → factor == 30 (cross-frame local).
    let locals_31 = load_locals_at(&mut handler, step_at_line(&reader, 31));
    assert_eq!(
        local_int(&locals_31, "factor"),
        30,
        "factor at line 31 (ct/load-locals)"
    );

    // Cross-check against the raw reader so a load-locals regression that
    // silently drops the value can't pass by returning an empty frame.
    let s40 = step_at_line(&reader, 40);
    let raw_i = reader
        .variables_at(s40)
        .and_then(|vars| {
            vars.iter().find_map(|v| {
                if reader.variable_name(v.variable_id) == Some("i") {
                    match &v.value {
                        ValueRecord::Int { i, .. } => Some(*i),
                        _ => None,
                    }
                } else {
                    None
                }
            })
        })
        .expect("raw reader also sees i at line 40");
    assert_eq!(raw_i, 15, "DAP load-locals and the raw reader must agree on i@40");
}

// ---------------------------------------------------------------------------
// (3) VALUE-ORIGIN — `ct/originChain` through the DAP handler.
//
// This is the CLOSED §5.2 gap: value-origin now resolves over the STANDARD
// DAP path for GDScript because the recorder BUNDLES each recorded `.gd`'s
// source text into the `.ct` and `Handler::load_bundled_sources` extracts it
// so `Handler::materialized_origin_chain` reads the self-contained copy — no
// explicit sources-root hook, no on-disk project. The assertions below match
// the strong shapes `origin_python_dap_test.rs` and the bespoke
// `verify_gdscript_materialized_trace_time_travel_and_origin.rs` assert (which
// only ever worked because it passed `Some(fixture_dir())` explicitly).
// ---------------------------------------------------------------------------

#[test]
fn test_gdscript_dap_value_origin_resolves_over_standard_dap_path() {
    let reader = open_reader();
    let mut handler = build_handler(Arc::clone(&reader));

    // `i = i + 5` (line 40): a Computational reassignment. The chain reaches
    // back to the prior write of `i`; the terminator is Computational and the
    // terminating hop's operand snapshots include the prior `i` — the same
    // shape Python's `computational_origin` fixture asserts.
    let s40 = step_at_line(&reader, 40);
    let chain_i = origin_chain(&mut handler, "i", s40);
    assert_eq!(
        chain_i.terminator.kind,
        TerminatorKind::Computational,
        "reassigned-local `i` must terminate Computational over the standard DAP path \
         (§5.2 bundled-source resolution). Got chain: {chain_i:?}"
    );
    let computational = chain_i
        .hops
        .iter()
        .find(|h| h.kind == OriginKind::Computational)
        .unwrap_or_else(|| panic!("expected a Computational hop for `i`, got {:?}", chain_i.hops));
    let operands: Vec<&str> = computational
        .operand_snapshots
        .iter()
        .map(|o| o.name.as_str())
        .collect();
    assert!(
        operands.contains(&"i"),
        "the reassignment's operand snapshots must include the prior `i`; got {operands:?}"
    );
    assert!(
        computational.source_text.contains("i = i + 5"),
        "the Computational hop must sit on the reassignment line, got {:?}",
        computational.source_text
    );

    // `var r = scale(i)` (line 41; r's write is captured on the following step,
    // line 42). A plain `r = scale(i)` classifies as FunctionCall — a subtype
    // of the Computational terminator — with the callee `scale` named in the
    // source expression, exactly as Python/Ruby `x = f()` does.
    let s42 = step_at_line(&reader, 42);
    let chain_r = origin_chain(&mut handler, "r", s42);
    assert_eq!(
        chain_r.terminator.kind,
        TerminatorKind::Computational,
        "return-derived `r` terminator (Python/Ruby FunctionCall shape) over the DAP path. \
         Got chain: {chain_r:?}"
    );
    let call_hop = chain_r
        .hops
        .iter()
        .find(|h| {
            matches!(
                h.kind,
                OriginKind::FunctionCall | OriginKind::ReturnCapture | OriginKind::FunctionReturn
            )
        })
        .unwrap_or_else(|| {
            panic!(
                "expected a FunctionCall/Return hop for `var r = scale(i)`, got {:?} (terminator={:?})",
                chain_r.hops, chain_r.terminator
            )
        });
    assert!(
        call_hop.source_expr.contains("scale"),
        "the return-derived hop must name the callee `scale`, got source_expr={:?}",
        call_hop.source_expr
    );

    // The eager per-local `originSummary` the State Pane attaches shares the
    // same materialized origin algorithm, so `ct/load-locals` now marks i's
    // origin with the resolved (non-`unknownSource`) terminator too.
    let locals_40 = load_locals_at(&mut handler, s40);
    let i_local = locals_40
        .iter()
        .find(|l| l.get("expression").and_then(JsonValue::as_str) == Some("i"))
        .expect("i present");
    let summary_kind = i_local
        .get("originSummary")
        .and_then(|s| s.get("terminatorKind"))
        .and_then(JsonValue::as_str);
    assert_ne!(
        summary_kind,
        Some("unknownSource"),
        "load-locals originSummary must resolve (not unknownSource) now that sources are bundled: {i_local:?}"
    );
    assert_eq!(
        summary_kind,
        Some("computational"),
        "load-locals originSummary for `i` should be the Computational shape: {i_local:?}"
    );
}

// ---------------------------------------------------------------------------
// Fixture-integrity guard.
// ---------------------------------------------------------------------------

#[test]
fn test_gdscript_dap_fixture_is_present() {
    assert!(
        fixture_ct().is_file(),
        "GDScript DAP fixture missing under {} — see the file header",
        fixture_dir().display()
    );
}
