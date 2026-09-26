//! Issue #689 — a replay refused by the free-tier daily quota must be a NAMED,
//! PROPAGATED failure, not silence and not `worker process exited with 3`.
//!
//! # What the product actually does when the quota runs out
//!
//! Enforcement lives in the sibling repo `codetracer-native-backend`. Its
//! `src/licensing/cli.rs::emit_replay_start_block` writes one JSON line to
//! **stderr** and exits **3**:
//!
//! ```text
//! {"result":"blocked","stop_reason":{"code":"daily_replay_limit_reached","count":5,"limit":5}}
//! ```
//!
//! That repo's
//! `tests/licensing_integration_test.rs::e2e_free_license_still_uses_daily_replay_limit`
//! pins the **exit code 3** and the **JSON shape** — but read what it actually
//! drives before relying on it for more: it runs `license session-harness`,
//! which selects `SessionStopOutput::JsonHarness` and therefore asserts against
//! **stdout**. The `Production` variant this side depends on — the one that
//! routes the same JSON to **stderr** (`cli.rs:898`, reached via
//! `SessionRunOptions::production`, `cli.rs:805`) — is NOT covered by that test.
//! So the stream the parser below reads is established by source reading, not
//! by a sibling assertion, and it is the one link in this chain that no test on
//! either side pins. If `emit_replay_start_block` ever moves the production
//! line to stdout, everything here stays green and the user goes back to
//! silence.
//!
//! Before this test existed, `codetracer` threw that away twice over:
//!
//! 1. `ReplayWorker::start` reported `"worker process exited with <status>
//!    before creating socket"` and never parsed the JSON — the cryptic
//!    Rust-side message in the issue.
//! 2. `dap_server::task_thread` handled the resulting `Err` with `?`, which
//!    returns from the worker thread. Nothing was written to the DAP client,
//!    which had already been told `launch` succeeded and then waited forever
//!    for a `stopped` event — the C-side symptom, "nothing happens at all".
//!    `tests/test_harness/mod.rs` documents that deadlock verbatim.
//!
//! # Why a stub worker and not the real one
//!
//! `ct-native-replay` is not built by `cargo test` in this crate, and driving
//! the real one to its quota would take five successful replays of a real
//! recording plus a mutation of the user's own usage counter. The contract
//! under test is entirely on THIS side of the process boundary: given a worker
//! that exits 3 with that JSON on stderr, does codetracer name the reason and
//! tell the client? A `/bin/sh` stub reproduces the observable the sibling
//! repo's own test pins, and the JSON literal below is copied from
//! `emit_replay_start_block`. This is the same stub-worker technique
//! `tests/run_id_rendezvous.rs` uses for the rendezvous contract.
//!
//! The mock is therefore the *worker process*, and nothing else: the real
//! `ReplayWorker::start`, the real `dap-server` binary, the real DAP framing
//! and the real notification route are all exercised.

#![cfg(unix)]

use db_backend::dap::{self, DapClient, DapMessage};
use db_backend::recreator_session::{DAILY_REPLAY_LIMIT_REACHED, ReplayWorkerStartError, parse_worker_stop_reason};
use db_backend::transport::DapTransport;
use serde_json::json;
use std::io::BufReader;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

/// The exact line `codetracer-native-backend`'s
/// `src/licensing/cli.rs::emit_replay_start_block` writes to stderr in
/// `SessionStopOutput::Production` mode before `std::process::exit(3)`.
const QUOTA_BLOCK_JSON: &str =
    r#"{"result":"blocked","stop_reason":{"code":"daily_replay_limit_reached","count":5,"limit":5}}"#;

/// The only user-facing wording the licensing spec specifies for the free-tier
/// replay limit —
/// `codetracer-specs/Planned-Features/CodeTracer-End-User-Licensing.md`
/// §3.6 step 4. Nothing here invents a second vocabulary.
const SPEC_UPGRADE_SENTENCE: &str = "Free tier: 5 replays per day. Visit https://codetracer.com/pricing to upgrade.";

/// The message issue #689 calls cryptic. No user-visible text may contain it.
const CRYPTIC_MESSAGE_FRAGMENT: &str = "before creating socket";

/// Write an executable `/bin/sh` stub that impersonates `ct-native-replay
/// replay-worker` for one specific outcome: emit `stderr_line` on stderr and
/// exit with `code`. It never creates a socket, exactly like a worker the
/// licensing module refused to start.
fn write_stub_worker(dir: &Path, name: &str, stderr_line: &str, code: i32) -> PathBuf {
    let path = dir.join(name);
    let mut file = std::fs::File::create(&path).expect("create stub worker");
    // `printf %s\n` rather than `echo` so a payload containing backslashes is
    // written verbatim on every /bin/sh (dash's `echo` interprets them).
    writeln!(file, "#!/bin/sh\nprintf '%s\\n' '{stderr_line}' >&2\nexit {code}").expect("write stub worker script");
    drop(file);
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).expect("chmod stub worker");
    path
}

/// A trace folder whose only contents are an empty `rr/` directory.
///
/// `dap_server::resolve_replay_trace_path` returns `<folder>/rr` for exactly
/// this shape, which is what routes the launch down the replay-worker path
/// instead of the CTFS/materialized path. Nothing reads inside it — the stub
/// worker dies before any trace byte is touched.
fn write_rr_trace_folder(dir: &Path) -> PathBuf {
    let folder = dir.join("trace");
    std::fs::create_dir_all(folder.join("rr")).expect("create rr trace folder");
    folder
}

// ---------------------------------------------------------------------------
// 1. The parser
// ---------------------------------------------------------------------------

#[test]
fn stop_reason_is_parsed_out_of_a_mixed_stderr_stream() {
    // The worker's stderr is not pure JSON: it interleaves free-form log lines
    // with the licensing module's machine-readable decision. A parser that
    // required the whole stream to be JSON would find nothing.
    let stderr = format!("[worker] starting up\n{QUOTA_BLOCK_JSON}\n[worker] exiting\n");
    let reason = parse_worker_stop_reason(&stderr).expect("stop reason must be found in a mixed stderr stream");
    assert_eq!(reason.code, DAILY_REPLAY_LIMIT_REACHED);
    assert_eq!(reason.count, Some(5));
    assert_eq!(reason.limit, Some(5));
}

#[test]
fn stderr_without_a_stop_reason_parses_to_none() {
    // Negative control for the parser: a worker that crashed for an unrelated
    // reason must NOT be reported as a quota block. Includes a well-formed
    // JSON line that carries no `stop_reason`, because "it is JSON" is not the
    // property being tested.
    assert!(parse_worker_stop_reason("").is_none());
    assert!(parse_worker_stop_reason("Segmentation fault\n").is_none());
    assert!(parse_worker_stop_reason(r#"{"result":"completed"}"#).is_none());
}

// ---------------------------------------------------------------------------
// 2. The typed error out of `ReplayWorker::start`
// ---------------------------------------------------------------------------

#[test]
fn quota_refusal_produces_a_typed_named_error() {
    let temp = tempfile::tempdir().expect("create temp dir");
    let stub = write_stub_worker(temp.path(), "quota-worker", QUOTA_BLOCK_JSON, 3);
    let trace_folder = write_rr_trace_folder(temp.path());

    let mut worker = db_backend::recreator_session::ReplayWorker::new("quota-test", 0, &stub, &trace_folder.join("rr"));
    let err = worker
        .start()
        .expect_err("a worker that exits 3 must not report success");

    let typed = err
        .downcast_ref::<ReplayWorkerStartError>()
        .unwrap_or_else(|| panic!("start() must return a ReplayWorkerStartError; got: {err}"));

    assert!(
        typed.is_daily_replay_limit_reached(),
        "the quota block must be recognised by NAME, not by substring; code was {:?}, detail was {}",
        typed.code(),
        typed.detail
    );
    let reason = typed.stop_reason.as_ref().expect("quota refusal carries a stop reason");
    assert_eq!(reason.count, Some(5), "the usage count must survive to the caller");
    assert_eq!(reason.limit, Some(5), "the daily limit must survive to the caller");

    // The rendered message is the spec's sentence and nothing else. The two
    // assertions are independent: one would pass on a message that also
    // carried the old cryptic text appended to it.
    let rendered = typed.to_string();
    assert_eq!(
        rendered, SPEC_UPGRADE_SENTENCE,
        "the quota message must be §3.6's wording verbatim"
    );
    assert!(
        !rendered.contains(CRYPTIC_MESSAGE_FRAGMENT),
        "the cryptic message from issue #689 must not survive: {rendered}"
    );
}

#[test]
fn a_worker_that_exits_without_a_stop_reason_is_not_reported_as_a_quota_block() {
    // §7b: an unfalsified negative control is a self-comparison wearing a
    // negation. This arm makes `is_daily_replay_limit_reached` FAIL — same
    // exit code 3, same transport failure, no licensing JSON — so the
    // assertion above is known to discriminate on the reason rather than on
    // "the worker died".
    let temp = tempfile::tempdir().expect("create temp dir");
    let stub = write_stub_worker(temp.path(), "crashing-worker", "Segmentation fault", 3);
    let trace_folder = write_rr_trace_folder(temp.path());

    let mut worker = db_backend::recreator_session::ReplayWorker::new("crash-test", 0, &stub, &trace_folder.join("rr"));
    let err = worker
        .start()
        .expect_err("a worker that exits 3 must not report success");

    let typed = err
        .downcast_ref::<ReplayWorkerStartError>()
        .unwrap_or_else(|| panic!("start() must return a ReplayWorkerStartError; got: {err}"));

    assert!(
        !typed.is_daily_replay_limit_reached(),
        "a crash with no licensing JSON must not be dressed up as a quota block"
    );
    assert_eq!(
        typed.code(),
        None,
        "no stop reason was emitted, so none may be invented"
    );
    assert!(
        typed.to_string().contains("Segmentation fault"),
        "an unclassified failure must still carry the worker's own stderr: {typed}"
    );
}

// ---------------------------------------------------------------------------
// 3. The DAP client must hear about it
// ---------------------------------------------------------------------------

fn terminate_child(child: &mut Child) {
    child.kill().ok();
    child.wait().ok();
}

/// End to end over the real `dap-server --stdio` binary: a launch whose worker
/// is refused by the quota must produce a message on the wire.
///
/// **This is the arm that discriminates the C-language symptom.** "No editor
/// opens" is true both before and after the fix (Verification-Harness-Traps
/// §7), so the assertion is not about absence: it is that a `ct/notification`
/// event carrying the spec's sentence ARRIVES, within a bound far shorter than
/// the 350 s hang the old code produced. With the production change reverted
/// this test times out with no message at all after `configurationDone`.
#[test]
fn a_quota_refused_launch_reaches_the_dap_client() {
    let temp = tempfile::tempdir().expect("create temp dir");
    let stub = write_stub_worker(temp.path(), "quota-worker", QUOTA_BLOCK_JSON, 3);
    let trace_folder = write_rr_trace_folder(temp.path());

    let bin = env!("CARGO_BIN_EXE_replay-server");
    let mut child = Command::new(bin)
        .arg("dap-server")
        .arg("--stdio")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        // The worker's startup timeout is otherwise 30 s; the stub exits at
        // once, but pinning it keeps a hung stub from stretching the test.
        .env("CODETRACER_REPLAY_WORKER_STARTUP_TIMEOUT_SECS", "5")
        .spawn()
        .unwrap_or_else(|err| panic!("failed to spawn db-backend: {err}"));

    let mut writer = child.stdin.take().expect("missing child stdin");
    let mut client = DapClient::default();

    let reader_stdout = child.stdout.take().expect("missing child stdout");
    let (tx, rx) = mpsc::channel::<Result<DapMessage, String>>();
    thread::spawn(move || {
        let mut reader = BufReader::new(reader_stdout);
        loop {
            match dap::read_dap_message_from_reader(&mut reader) {
                Ok(msg) => {
                    if tx.send(Ok(msg)).is_err() {
                        break;
                    }
                }
                Err(err) => {
                    let _ = tx.send(Err(err.to_string()));
                    break;
                }
            }
        }
    });

    for request in [
        client.request("initialize", json!({})),
        client.request(
            "launch",
            json!({
                "traceFolder": trace_folder,
                "ctRRWorkerExe": stub,
            }),
        ),
        client.request("configurationDone", json!({})),
    ] {
        writer
            .send(&request)
            .unwrap_or_else(|err| panic!("failed to send DAP request: {err}"));
    }

    // Drain until the notification arrives. The stream carries the
    // initialize/launch/configurationDone responses and the `initialized`
    // event first; none of them says anything about the quota.
    let deadline = std::time::Instant::now() + Duration::from_secs(30);
    let mut seen: Vec<String> = Vec::new();
    // Every `ct/notification` text, kept separately from `seen` so the failure
    // arm can tell TWO DIFFERENT DEFECTS APART (Verification-Harness-Traps
    // §20: a producer that collapses distinct causes onto one diagnostic).
    // Reverting `dap_server.rs` sends nothing at all; reintroducing a
    // `map_err(|e| format!(…))` on the error chain still sends a
    // `ct/notification`, but carrying the opaque blob instead of the spec's
    // sentence. Both used to print "produced no message", which is false for
    // the second and would send the next reader looking in the wrong file.
    let mut notification_texts: Vec<String> = Vec::new();
    let mut quota_notification: Option<String> = None;
    while std::time::Instant::now() < deadline && quota_notification.is_none() {
        let Ok(message) = rx.recv_timeout(Duration::from_millis(500)) else {
            continue;
        };
        let message = match message {
            Ok(message) => message,
            Err(err) => {
                seen.push(format!("<stream error: {err}>"));
                break;
            }
        };
        match message {
            DapMessage::Event(event) => {
                seen.push(format!("event {}", event.event));
                if event.event == "ct/notification" {
                    let text = event.body["text"].as_str().unwrap_or_default().to_string();
                    notification_texts.push(text.clone());
                    if text.contains("codetracer.com/pricing") {
                        quota_notification = Some(text);
                    }
                }
            }
            DapMessage::Response(response) => seen.push(format!("response {}", response.command)),
            DapMessage::Request(request) => seen.push(format!("request {}", request.command)),
        }
    }

    terminate_child(&mut child);

    let text = quota_notification.unwrap_or_else(|| {
        if notification_texts.is_empty() {
            panic!(
                "a launch refused by the daily replay quota produced NO ct/notification at all — \
                 this is issue #689's silent hang, and the failure is in dap_server.rs \
                 (the launch branch is losing the error instead of reporting it). \
                 Messages seen: {seen:?}"
            )
        }
        panic!(
            "a ct/notification DID reach the DAP client, but it does not carry the quota wording — \
             the typed ReplayWorkerStartError is being stringified somewhere on the error chain \
             (look for a `map_err(|e| format!(…))` between ReplayWorker::start and \
             dap_server::launch_failure_text, which defeats its `downcast_ref`). \
             Notification texts seen: {notification_texts:?}. Messages seen: {seen:?}"
        )
    });
    assert_eq!(
        text, SPEC_UPGRADE_SENTENCE,
        "the notification must carry §3.6's wording verbatim"
    );
    assert!(
        !text.contains(CRYPTIC_MESSAGE_FRAGMENT),
        "the cryptic message from issue #689 must not reach the user: {text}"
    );
}
