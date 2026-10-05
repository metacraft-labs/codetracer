//! A recording `replay-server` cannot read must SAY SO on the wire.
//!
//! # The defect
//!
//! A recording whose CTFS container predates this build's reader opened to
//! empty panes and no message of any kind. Measured against
//! `replay-server dap-server --stdio` and a real container-v4 recording, the
//! whole exchange was:
//!
//! ```text
//! response initialize success=true
//! event    initialized
//! response configurationDone success=true
//! response launch success=true
//! event    ct/listProcesses
//! event    ct/notification  "launch error: \"…\""   (an escaped Rust literal)
//! ```
//!
//! and the engine's log — the only place the cause existed — held the whole
//! diagnosis already:
//!
//! ```text
//! CTFS container version 4 is not readable: this reader reads versions 5
//! and 6. Re-record the trace, or regenerate the fixture with its producer
//! ```
//!
//! `refuse_unreadable_ctfs_version` had already decided that correctly, off
//! six header bytes. What it could not do was get the answer out: it returned
//! a `String`, which `launch_failure_text` renders with `{err:?}` as an
//! escaped Rust literal, and the only carrier out was a `ct/notification`
//! that no handshake can key on — because the engine also emits one of those
//! for a recording that opened perfectly well. So the sentence reached the
//! engine's log and stopped, the front-ends waited out their clocks, and the
//! user was told the engine had gone quiet. "We could not look" delivered as
//! "there was nothing to see".
//!
//! # What is asserted, and why absence is not the property
//!
//! "The panes are empty" is true before the fix and after it: the trace still
//! does not open, and it never will, because nothing about the file can be
//! changed to make this build read it. So the assertion is not about absence.
//! It is that a refusal ARRIVES carrying the reader's own sentence — the
//! container version it FOUND, the version it REQUIRES, and that the remedy is
//! re-recording — within a bound far shorter than the silence the old code
//! produced.
//!
//! Both carriers are required, and they are different jobs. `ct/launch-failed`
//! is what a handshake waiting for `stopped` can key on; `ct/notification` of
//! kind `Error` is what the GUI status bar already renders, and it cannot do
//! the first job because `dap_handler::complete_move` emits one for a trace
//! that opened perfectly well whose first step carries a recorded error event.
//! They must carry the same sentence, which is asserted — two wordings for one
//! fact is how one of them goes stale while every test stays green.
//!
//! The arm discriminates on the REASON, not on "the launch failed": at the
//! unmodified parent a notification does arrive. Every text seen is therefore
//! reported separately from the message list, so the failure output tells a
//! reader which defect they are looking at — no refusal event at all, versus
//! one that named the wrong thing.
//!
//! # No mocks
//!
//! The real `replay-server` binary, the real DAP framing, the real version
//! probe, the real launch path.
//!
//! The container is BUILT here rather than taken from the committed corpus,
//! and that is forced rather than preferred: every committed materialised
//! recording has been re-recorded to the current container version, so there
//! is no longer a v4 one to point at, and the MCR recordings that are still v3
//! and v4 belong to the replay-worker path and must NOT be refused here. So
//! this writes a container with the production writer and stamps its version
//! byte back, which is exactly what `dap_server.rs`'s own
//! `a_container_of_another_version_is_refused_by_name` does next door and for
//! the same reason: the current writer cannot stamp a superseded version, that
//! being what the bump means. Every other byte is what a writer produced.
//!
//! This also makes the fixture durable: a future re-recording cannot quietly
//! turn this case into a test of nothing.

#![cfg(unix)]
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use db_backend::ctfs_trace_reader::ctfs_container::write_minimal_ctfs;
use db_backend::dap::{self, DapClient, DapMessage};
use db_backend::transport::DapTransport;
use serde_json::json;
use std::io::BufReader;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

/// A recording at the container version this build writes and reads — the
/// CONTROL. Without it, a `setup` that refused EVERY trace would pass the
/// refusal arm above.
const READABLE_FIXTURE_FOLDER: &str = "trace";

/// The container version stamped over the refused fixture: the version the
/// recordings in the field carry.
const REFUSED_CONTAINER_VERSION: u8 = 4;

fn manifest_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

/// Byte 5 of a `.ct` file: the CTFS container version
/// (`ctfs-container.md` §1).
fn container_version(ct_path: &Path) -> u8 {
    let bytes = std::fs::read(ct_path).unwrap_or_else(|err| panic!("read {}: {err}", ct_path.display()));
    assert!(
        bytes.len() > 5,
        "{} is {} bytes — too short to be a CTFS container",
        ct_path.display(),
        bytes.len()
    );
    bytes[5]
}

/// A one-container recording folder holding a container at
/// `REFUSED_CONTAINER_VERSION`.
///
/// The container is written by the production writer and its version byte
/// stamped afterwards — see the module header for why that is the only
/// available shape. The members are the ones that make it a materialised
/// recording rather than a native bundle; nothing reads them, because the
/// version probe answers off the header.
fn refused_recording_folder(dir: &Path) -> PathBuf {
    let folder = dir.join("recording");
    std::fs::create_dir_all(&folder).expect("create recording folder");
    let container = folder.join("trace.ct");
    write_minimal_ctfs(
        &container,
        &[("meta.dat", b"placeholder"), ("steps.dat", b"\x00\x00\x00\x00")],
    )
    .expect("write container");

    let mut bytes = std::fs::read(&container).expect("read container");
    assert!(
        bytes.len() > 5 && bytes[..5] == [0xC0, 0xDE, 0x72, 0xAC, 0xE2],
        "the writer no longer produces a CTFS container, so this fixture is not a recording"
    );
    assert_ne!(
        bytes[5], REFUSED_CONTAINER_VERSION,
        "the writer already stamps version {REFUSED_CONTAINER_VERSION}, so stamping it is a no-op \
         and this fixture no longer demonstrates a version this build refuses"
    );
    bytes[5] = REFUSED_CONTAINER_VERSION;
    std::fs::write(&container, &bytes).expect("stamp container version");
    folder
}

/// The event the engine uses to say a `launch` it acknowledged cannot
/// succeed (`dap_server::LAUNCH_FAILED_EVENT`).
const LAUNCH_FAILED_EVENT: &str = "ct/launch-failed";

struct Exchange {
    /// Every message seen, in arrival order, rendered for the failure output.
    seen: Vec<String>,
    /// Every refusal text, kept apart from `seen` so the failure arm can tell
    /// "no refusal at all" from "a refusal that named the wrong thing".
    ///
    /// Both carriers are collected: the `ct/launch-failed` event the handshake
    /// waits key on, and the `ct/notification` of kind `Error` the GUI status
    /// bar renders. They must say the SAME thing, which is asserted below —
    /// two wordings for one fact is how one of them goes stale.
    refusal_texts: Vec<String>,
    /// The `ct/launch-failed` messages only.
    launch_failed_texts: Vec<String>,
    /// The kind-`Error` `ct/notification` texts only.
    error_notification_texts: Vec<String>,
    /// Whether a `stopped` event arrived — the signal a front-end's handshake
    /// is actually waiting for.
    stopped: bool,
    /// The `launch` response's `success`, if a launch response arrived.
    launch_success: Option<bool>,
    elapsed: Duration,
}

fn terminate_child(child: &mut Child) {
    child.kill().ok();
    child.wait().ok();
}

/// Run `initialize` → `configurationDone` → `launch` against a real
/// `replay-server --stdio` and drain until `stopped` or an error notification
/// arrives, or `budget` expires.
///
/// The request order is the front-ends' own: `headless_session.nim` and the
/// SDK's `debugger_session.nim` both send `configurationDone` before `launch`.
fn drive_launch(trace_folder: &Path, budget: Duration) -> Exchange {
    let bin = env!("CARGO_BIN_EXE_replay-server");
    let mut child = Command::new(bin)
        .arg("dap-server")
        .arg("--stdio")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap_or_else(|err| panic!("failed to spawn replay-server: {err}"));

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
        client.request("configurationDone", json!({})),
        client.request("launch", json!({ "traceFolder": trace_folder })),
    ] {
        writer
            .send(&request)
            .unwrap_or_else(|err| panic!("failed to send DAP request: {err}"));
    }

    let started = Instant::now();
    let deadline = started + budget;
    // A GRACE WINDOW AFTER THE FIRST REFUSAL, not an immediate break. The two
    // carriers are queued back to back, so stopping at the first one read
    // whichever happened to be sent first and reported the other as missing —
    // which is a test that cannot tell "the engine sent one carrier" from "the
    // engine sent both and we stopped listening".
    let mut settle_by: Option<Instant> = None;
    const SETTLE: Duration = Duration::from_millis(1500);
    let mut exchange = Exchange {
        seen: Vec::new(),
        refusal_texts: Vec::new(),
        launch_failed_texts: Vec::new(),
        error_notification_texts: Vec::new(),
        stopped: false,
        launch_success: None,
        elapsed: Duration::ZERO,
    };

    while Instant::now() < deadline {
        if let Some(settle) = settle_by
            && Instant::now() >= settle
        {
            break;
        }
        let Ok(message) = rx.recv_timeout(Duration::from_millis(100)) else {
            continue;
        };
        let message = match message {
            Ok(message) => message,
            Err(err) => {
                exchange.seen.push(format!("<stream error: {err}>"));
                break;
            }
        };
        match message {
            DapMessage::Event(event) => {
                exchange.seen.push(format!("event {}", event.event));
                if event.event == "stopped" {
                    exchange.stopped = true;
                }
                if event.event == LAUNCH_FAILED_EVENT {
                    let text = event
                        .body
                        .get("message")
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or_default()
                        .to_string();
                    exchange.launch_failed_texts.push(text.clone());
                    exchange.refusal_texts.push(text);
                }
                if event.event == "ct/notification" {
                    let kind = event.body.get("kind").and_then(serde_json::Value::as_u64);
                    let text = event
                        .body
                        .get("text")
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or_default()
                        .to_string();
                    // Kind 2 is `NotificationKind::Error` (`task.rs`, a
                    // `Serialize_repr` enum, so the discriminant travels).
                    // Info / warning / success notifications are ordinary
                    // session traffic and are not refusals.
                    if kind == Some(2) {
                        exchange.error_notification_texts.push(text.clone());
                        exchange.refusal_texts.push(text);
                    }
                }
            }
            DapMessage::Response(response) => {
                exchange
                    .seen
                    .push(format!("response {} success={}", response.command, response.success));
                if response.command == "launch" {
                    exchange.launch_success = Some(response.success);
                }
            }
            DapMessage::Request(request) => exchange.seen.push(format!("request {}", request.command)),
        }
        if exchange.stopped {
            // The trace opened; nothing more is coming that this case reads.
            break;
        }
        if !exchange.refusal_texts.is_empty() && settle_by.is_none() {
            settle_by = Some(Instant::now() + SETTLE);
        }
    }
    exchange.elapsed = started.elapsed();

    terminate_child(&mut child);
    exchange
}

/// THE ARM. A container-version-4 recording must reach the client as a NAMED
/// refusal carrying the reader's own words.
///
/// With `dap_server.rs`'s fall-through restored, this fails on the text: the
/// notification that arrives says `launch error: Os { code: 2, kind: NotFound,
/// message: "No such file or directory" }`, which names no version, no
/// expected version and no remedy.
#[test]
fn a_container_version_4_recording_is_refused_by_name_on_the_wire() {
    let temp = tempfile::tempdir().expect("create temp dir");
    let folder = refused_recording_folder(temp.path());
    assert_eq!(
        container_version(&folder.join("trace.ct")),
        REFUSED_CONTAINER_VERSION,
        "the fixture must carry the version the issue reports, or this case demonstrates nothing"
    );

    let exchange = drive_launch(&folder, Duration::from_secs(60));

    assert!(
        !exchange.launch_failed_texts.is_empty(),
        "a recording this build cannot read produced NO `{LAUNCH_FAILED_EVENT}` at all in {:?}. \
         The engine knows why it cannot open it; the front-end's handshake has no way to learn \
         it and waits out its clock. Messages seen: {:?}",
        exchange.elapsed,
        exchange.seen
    );
    assert!(
        !exchange.error_notification_texts.is_empty(),
        "the GUI's carrier went missing: no kind-Error `ct/notification` arrived, so the status \
         bar has nothing to render. Messages seen: {:?}",
        exchange.seen
    );
    assert_eq!(
        exchange.launch_failed_texts, exchange.error_notification_texts,
        "the two carriers must say the SAME thing. Two wordings for one fact is how one of them \
         goes stale while every test stays green."
    );

    let refusal = exchange.refusal_texts.join(" | ");

    assert!(
        refusal.contains("container version 4"),
        "the refusal must name the container version it FOUND. A user who is not told which \
         version their recording carries cannot tell a stale recording from a broken build. \
         Refusals seen: {:?}",
        exchange.refusal_texts
    );
    // PINNED TO THE SENTENCE, numbers included, the same way
    // `dap_server.rs`'s own `a_container_of_another_version_is_refused_by_name`
    // pins it. When the readable set moves this goes red, and that is the
    // intent: a refusal that names a floor is the one thing here a human has
    // to re-read when the floor changes.
    assert!(
        refusal.contains("this reader reads versions 5 and 6"),
        "the refusal must name the versions this build REQUIRES, or 'not readable' is a dead end. \
         Refusals seen: {:?}",
        exchange.refusal_texts
    );
    assert!(
        refusal.to_lowercase().contains("re-record"),
        "the refusal must name the REMEDY. The file is intact and nothing can be done to it; \
         the only way forward is to re-record the program, and a user who is not told that will \
         go looking for a repair that does not exist. Refusals seen: {:?}",
        exchange.refusal_texts
    );
    assert!(
        !refusal.to_lowercase().contains("corrupt"),
        "a correctly written older recording must NOT be reported as corrupt — its bytes are \
         intact. Refusals seen: {:?}",
        exchange.refusal_texts
    );
    assert!(
        !refusal.contains('\\'),
        "a debug-escaped Rust literal has reached the client instead of a sentence: {refusal:?}"
    );
}

/// THE CONTROL. A recording this build CAN read must still open, so the arm
/// above is known to discriminate on the container version rather than
/// refusing everything.
///
/// `trace/trace.ct` is this crate's own committed recording at the container
/// version the writer stamps. The guard asserts that, so a day on which the
/// floor moves again makes this control fail by name instead of silently
/// becoming a second copy of the refusal arm.
#[test]
fn a_readable_recording_still_opens_and_is_not_refused_on_version() {
    let folder = manifest_dir().join(READABLE_FIXTURE_FOLDER);
    let container = folder.join("trace.ct");
    assert!(
        container.is_file(),
        "{} is missing; the refusal arm has no control without it",
        container.display()
    );
    assert_ne!(
        container_version(&container),
        REFUSED_CONTAINER_VERSION,
        "{} is itself at container version {REFUSED_CONTAINER_VERSION}, so it cannot serve as the \
         control for a version refusal. Re-record it, or point the control at a current recording.",
        container.display()
    );

    let exchange = drive_launch(&folder, Duration::from_secs(90));

    let refusal = exchange.refusal_texts.join(" | ");
    assert!(
        !refusal.contains("container version"),
        "a recording at a readable container version was refused ON VERSION: {refusal:?}. \
         Messages seen: {:?}",
        exchange.seen
    );
    assert_eq!(
        exchange.launch_success,
        Some(true),
        "the control's launch must be acknowledged. Messages seen: {:?}",
        exchange.seen
    );
    assert!(
        exchange.stopped,
        "the control must reach the `stopped` event every front-end's handshake waits for, \
         in {:?}. Without that, this control cannot tell a refusal apart from a trace that \
         merely fails to finish opening. Messages seen: {:?}",
        exchange.elapsed, exchange.seen
    );
}
