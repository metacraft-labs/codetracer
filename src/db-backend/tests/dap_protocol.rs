use db_backend::dap::{DapMessage, LaunchRequestArguments, ProtocolMessage, Response, from_json, to_json};
use serde_json::json;
use std::path::Path;
use std::sync::{Mutex, MutexGuard};

/// `db_backend::dap::INBOUND_PARSES` is process-global, and cargo runs the
/// tests of ONE test binary in threads of ONE process. Every test in this
/// file decodes DAP messages, so every test in this file bumps that counter —
/// which means the budget assertion below would otherwise be measuring
/// whichever of its neighbours happened to be running beside it.
///
/// This is the one real correctness trap in the whole check, and the answer
/// is that EVERY test here takes this lock, not just the one that asserts.
/// A new test in this file that calls `from_json` (or anything that reaches
/// it) must take it too, via [`counter_guard`].
static COUNTER_LOCK: Mutex<()> = Mutex::new(());

/// Take the counter lock, ignoring poisoning: a panic in one test (i.e. a
/// different failure) must not turn every other test in the file into a
/// second, misleading failure about a poisoned mutex.
fn counter_guard() -> MutexGuard<'static, ()> {
    COUNTER_LOCK.lock().unwrap_or_else(|e| e.into_inner())
}

#[test]
fn test_parse_initialize_request() {
    let _guard = counter_guard();
    let json_text = r#"{"seq":1,"type":"request","command":"initialize","arguments":{"adapterID":"noir"}}"#;
    let message = from_json(json_text).expect("valid message");
    match message {
        DapMessage::Request(req) => {
            assert_eq!(req.base.seq, 1);
            assert_eq!(req.command, "initialize");
            // println!("{:?}", req);
            assert_eq!(req.arguments["adapterID"], "noir");
        }
        _ => panic!("expected request"),
    }
}

#[test]
fn test_serialize_initialize_response() {
    let _guard = counter_guard();
    let body = json!({
        "supportsLoadedSourcesRequest": true,
        "supportsStepBack": true,
        "supportsConfigurationDoneRequest": true,
        "supportsDisassembleRequest": true,
        "supportsLogPoints": true,
        "supportsRestartRequest": true
    });
    let resp = Response {
        base: ProtocolMessage {
            seq: 2,
            type_: "response".to_string(),
        },
        request_seq: 1,
        success: true,
        command: "initialize".to_string(),
        message: None,
        body,
    };
    let original = DapMessage::Response(resp);
    let json_text = to_json(&original).expect("serialize");
    let deserialized = from_json(&json_text).expect("deserialize");
    assert_eq!(original, deserialized);
}

#[test]
fn test_session_sequence_parse() {
    let _guard = counter_guard();
    let messages = [
        r#"{"seq":1,"type":"request","command":"initialize","arguments":{}}"#,
        r#"{"seq":2,"type":"response","request_seq":1,"success":true,"command":"initialize","body":{"supportsLoadedSourcesRequest":true,"supportsStepBack":true,"supportsConfigurationDoneRequest":true,"supportsDisassembleRequest":true,"supportsLogPoints":true,"supportsRestartRequest":true}}"#,
        r#"{"seq":3,"type":"event","event":"initialized"}"#,
        r#"{"seq":4,"type":"request","command":"launch","arguments":{"program":"main"}}"#,
        r#"{"seq":5,"type":"response","request_seq":4,"success":true,"command":"launch"}"#,
    ];
    let parsed: Vec<_> = messages.iter().map(|m| from_json(m).unwrap()).collect();
    assert_eq!(parsed.len(), messages.len());
    match &parsed[0] {
        DapMessage::Request(req) => assert_eq!(req.command, "initialize"),
        _ => panic!("unexpected type"),
    }
    match &parsed[1] {
        DapMessage::Response(resp) => {
            assert_eq!(resp.command, "initialize");
            assert!(resp.body["supportsLoadedSourcesRequest"].as_bool().unwrap());
            assert!(resp.body["supportsStepBack"].as_bool().unwrap());
            assert!(resp.body["supportsConfigurationDoneRequest"].as_bool().unwrap());
            assert!(resp.body["supportsDisassembleRequest"].as_bool().unwrap());
            assert!(resp.body["supportsLogPoints"].as_bool().unwrap());
            assert!(resp.body["supportsRestartRequest"].as_bool().unwrap());
        }
        _ => panic!("unexpected type"),
    }
    match &parsed[2] {
        DapMessage::Event(ev) => assert_eq!(ev.event, "initialized"),
        _ => panic!("unexpected type"),
    }
    match &parsed[4] {
        DapMessage::Response(resp) => {
            assert!(resp.success);
            assert_eq!(resp.command, "launch");
        }
        _ => panic!("unexpected type"),
    }
}

// ---------------------------------------------------------------------------
// Issue #222 — inbound deserialization budget, and the source-scan backstop
// that keeps the budget honest.
// ---------------------------------------------------------------------------

/// How many times a single inbound DAP request may be handed to serde on its
/// way from raw bytes to typed arguments.
///
/// Issue #222: it was THREE on the native path — text -> `Value` in
/// `dap::from_json`, `Value` -> `dap::Request` in the same function (which
/// also deep-copied `arguments` into a second `Value`), and finally
/// `arguments.clone()` -> `T` in `Request::load_args` — and FOUR in the
/// browser worker, which parsed the whole payload a further time up front to
/// have a `seq` on hand *in case* decoding failed.
///
/// Two is the floor for the shape the protocol actually has: the message is
/// self-describing, so its `type` cannot be known without reading it once,
/// and the per-command `arguments` cannot be typed until the command is
/// known. Everything above two is re-reading bytes already in hand.
///
/// TODO(#222): this is set to the DEFECT's own number, not to the floor. It
/// is here first, and deliberately loose, so that the instrument is proved to
/// measure the tree as it stands before anything is changed underneath it —
/// the fix commit lowers it to 2. A budget written after the fix would only
/// ever have been observed passing.
const INBOUND_PARSE_BUDGET: usize = 3;

/// A representative inbound request: `launch` is the one the native server
/// decodes most expensively (`dap_server.rs` calls
/// `load_args::<LaunchRequestArguments>()` from two separate arms), and its
/// arguments struct is `deny_unknown_fields`, so a decode that silently did
/// nothing could not pass the assertions below.
const LAUNCH_REQUEST: &str =
    r#"{"seq":4,"type":"request","command":"launch","arguments":{"program":"main","noDebug":false}}"#;

/// The gate for #222.
///
/// Drives one whole inbound request — raw text through `from_json`, then
/// typed `arguments` through `load_args` — with
/// `db_backend::dap::INBOUND_PARSES` reset, and holds the number of serde
/// passes it took to a budget.
///
/// It measures rather than inspects, so it cannot be satisfied by moving a
/// parse somewhere else: every deserialization of client bytes goes through
/// the `dap::parse_inbound_*` helpers, which is what the counter counts and
/// what `test_no_uncounted_inbound_deserialization` (below) keeps true.
#[test]
fn test_inbound_request_deserialization_budget() {
    let _guard = counter_guard();

    db_backend::dap::reset_inbound_parse_count();

    let message = from_json(LAUNCH_REQUEST).expect("valid launch request");
    let DapMessage::Request(request) = message else {
        panic!("expected a request");
    };
    let args: LaunchRequestArguments = request.load_args().expect("valid launch arguments");

    let passes = db_backend::dap::inbound_parse_count();

    // The decode really happened — otherwise a "budget" of zero passes would
    // be trivially reachable by not parsing anything.
    assert_eq!(request.base.seq, 4);
    assert_eq!(request.command, "launch");
    assert_eq!(args.program.as_deref(), Some("main"));
    assert_eq!(args.no_debug, Some(false));

    assert!(
        passes <= INBOUND_PARSE_BUDGET,
        "{passes} inbound deserialization passes over one `launch` request, budget \
         {INBOUND_PARSE_BUDGET} — the payload is being re-parsed after it has already been \
         read (see the pass inventory on INBOUND_PARSE_BUDGET, and issue #222). Route the \
         extra decode through data already in hand rather than going back to the bytes; if \
         a pass is genuinely required, raise the budget in the same commit that explains \
         which one and why."
    );

    // Equally a failure: fewer passes than budgeted means the budget has gone
    // stale and stopped constraining anything. Tighten it instead.
    assert_eq!(
        passes, INBOUND_PARSE_BUDGET,
        "one `launch` request now costs only {passes} inbound deserialization passes, but the \
         budget still says {INBOUND_PARSE_BUDGET} — lower INBOUND_PARSE_BUDGET to {passes} so \
         it keeps holding the line it was written to hold (#222)."
    );
}

/// The backstop for #222.
///
/// The budget above can only see passes that go through the counting
/// helpers. A future edit that calls `serde_json::from_str` / `from_value`
/// directly in `dap.rs` adds a pass the counter never increments, and the
/// budget stays green while the defect comes back. So the inbound decoder's
/// own source file is scanned: the only bare `serde_json` entry points it may
/// contain are the ones inside the counting helpers themselves.
///
/// Modelled on `correlation_markers_test.rs::test_no_protocol_specific_shims_in_recorders`,
/// which reads its allowlist from the same `tests/audit/` directory.
#[test]
fn test_no_uncounted_inbound_deserialization() {
    let allowlist_path = Path::new("tests/audit/inbound_parse_helpers.allowlist.toml");
    assert!(
        allowlist_path.is_file(),
        "missing allowlist file at {}",
        allowlist_path.display()
    );
    let allowlist: toml::Value =
        toml::from_str(&std::fs::read_to_string(allowlist_path).expect("read allowlist")).expect("parse allowlist");

    let scanned = allowlist["scan"].as_array().expect("`scan` is a list of files");
    assert!(!scanned.is_empty(), "the audit must scan at least one file");

    let waivers = allowlist["allow"].as_array().expect("`allow` is a list of waivers");

    for file in scanned {
        let rel = file.as_str().expect("`scan` entries are paths");
        let path = Path::new(rel);
        let source = std::fs::read_to_string(path).unwrap_or_else(|e| panic!("read {rel}: {e}"));

        for waiver in waivers {
            let waiver_file = waiver["file"].as_str().expect("waiver `file`");
            if waiver_file != rel {
                continue;
            }
            let needle = waiver["needle"].as_str().expect("waiver `needle`");
            let budget = waiver["budget"].as_integer().expect("waiver `budget`") as usize;

            // Comment lines are prose about the rule (including this rule's
            // own explanation) and are not calls.
            let hits: Vec<usize> = source
                .lines()
                .enumerate()
                .filter(|(_, line)| !line.trim_start().starts_with("//"))
                .filter(|(_, line)| line.contains(needle))
                .map(|(i, _)| i + 1)
                .collect();

            assert_eq!(
                hits.len(),
                budget,
                "{rel} contains {} call(s) to `{needle}` (lines {hits:?}), but the inbound-path \
                 audit allows {budget}. Inbound payloads must be deserialized through the \
                 `dap::parse_inbound_*` helpers, which increment `dap::INBOUND_PARSES`; a bare \
                 call is a pass that `test_inbound_request_deserialization_budget` cannot see, \
                 and an invisible pass is how #222 got in. Waiver reason on record: {}",
                hits.len(),
                waiver["reason"].as_str().unwrap_or("(none given)")
            );
        }
    }
}
