//! A `ct/start-replay` the session manager cannot carry out is ANSWERED, with
//! `success: false` and a message naming the cause, instead of only being
//! logged.
//!
//! The client of `ct/start-replay` (the GUI's main process, `ct host`'s
//! server, the daemon's clients) waits for its answer; the request names no
//! deadline.  When the start failed and the session manager only logged
//! "Can't handle DAP message", that client waited for ever, and the GUI drew
//! its panes over a session with no backend.  Three ways a start fails before
//! any replay runs are exercised here:
//!
//! * the replay's socket path is longer than a Unix socket address holds
//!   (`sockaddr_un.sun_path`, unix(7)): the session manager refuses to bind
//!   it, naming the path and the limit (`SocketPathTooLong`);
//! * the replay command cannot be started at all (no such file);
//! * the replay command starts and exits before it connects to its socket:
//!   the session manager waited in `accept` for ever, holding the lock every
//!   request is dispatched under, so it answered nothing more at all.
//!
//! Each arm is run against the daemon (`session-manager daemon start`, the
//! answer routed to the client that asked) and the spawn arm also against the
//! single-client session manager the GUI starts (`session-manager` with no
//! arguments, the answer on its one connection).  After a refusal the session
//! manager still answers: the daemon's `ct/ping` is the control that the
//! failure did not wedge its dispatch loop.
//!
//! What is real: the production `session-manager` binary, its sockets, the
//! DAP framing the GUI writes.  Nothing stands in for a component.  The
//! "replay command" of the spawn arm is a path that does not exist and that
//! of the early-exit arm is `false(1)`, which exits 1 at once: each is the
//! failure being tested.  The socket arm never reaches the spawn.

#![cfg(unix)]
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

#[path = "support/mcp_harness.rs"]
mod mcp_harness;

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use tokio::process::{Child, Command};
use tokio::time::{Instant, timeout};

/// How long a refusal may take.  It needs no replay to run, so it arrives
/// in milliseconds; the bound only turns the defect (no answer at all) into
/// a failure instead of a hung test.
const ANSWER_TIMEOUT: Duration = Duration::from_secs(20);

/// The replay command of the spawn arm: absent on every host.
const MISSING_REPLAY_SERVER: &str = "/nonexistent/codetracer-test/replay-server";

/// One DAP request frame, as the GUI's main process writes it
/// (`index/traces.nim`, `startReplayProcess`).
fn frame(message: &Value) -> Vec<u8> {
    let body = message.to_string();
    format!("Content-Length: {}\r\n\r\n{body}", body.len()).into_bytes()
}

fn start_replay_request(seq: i64, command: &str) -> Value {
    json!({
        "type": "request",
        "seq": seq,
        "command": "ct/start-replay",
        "arguments": [command, "dap-server"],
    })
}

/// Read from `stream` until a response to `command` arrives, and return it.
/// Panics, naming what did arrive, when none does within [`ANSWER_TIMEOUT`]
/// — which is what the unfixed session manager does with a failed start.
async fn response_to(stream: &mut UnixStream, command: &str) -> Value {
    let deadline = Instant::now() + ANSWER_TIMEOUT;
    let mut received = Vec::new();
    let mut buffer = vec![0u8; 8192];
    loop {
        for message in mcp_harness::dap_messages(&received) {
            if message.get("type").and_then(Value::as_str) == Some("response")
                && message.get("command").and_then(Value::as_str) == Some(command)
            {
                return message;
            }
        }
        let left = deadline.saturating_duration_since(Instant::now());
        match timeout(left, stream.read(&mut buffer)).await {
            Ok(Ok(0)) => panic!(
                "the session manager closed the connection without answering {command}; \
                 it sent: {:?}",
                mcp_harness::dap_messages(&received)
            ),
            Ok(Ok(n)) => received.extend_from_slice(&buffer[..n]),
            Ok(Err(err)) => panic!("reading the session manager's answer: {err}"),
            Err(_) => panic!(
                "no answer to {command} within {ANSWER_TIMEOUT:?}; the session manager sent: {:?}",
                mcp_harness::dap_messages(&received)
            ),
        }
    }
}

/// The refusal's message, after checking the response is one.
fn refusal_message(response: &Value) -> String {
    assert_eq!(
        response.get("success").and_then(Value::as_bool),
        Some(false),
        "a failed start answered as a success: {response}"
    );
    response
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or_else(|| panic!("a refusal without a message: {response}"))
        .to_owned()
}

/// A directory of exactly `len` bytes under `root`, created.
fn dir_of_length(root: &Path, len: usize) -> PathBuf {
    let prefix = root.join("t").as_os_str().len();
    assert!(
        prefix < len,
        "{} is too long for this check",
        root.display()
    );
    let dir = root.join("t".repeat(len - prefix + 1));
    assert_eq!(dir.as_os_str().len(), len);
    fs::create_dir_all(&dir).unwrap();
    dir
}

/// The daemon, with its own socket at a short path and its temporary
/// directory (where it makes each replay's socket) at `tmp`.
async fn start_daemon(root: &Path, tmp: &Path) -> (Child, PathBuf) {
    let server = mcp_harness::server_binary();
    mcp_harness::start_daemon_with_env(
        &server,
        root,
        Path::new(MISSING_REPLAY_SERVER),
        &[
            ("CODETRACER_TMP_PATH", tmp.as_os_str()),
            ("CODETRACER_HOME", root.join("home").as_os_str()),
        ],
    )
    .await
}

#[tokio::test]
async fn the_daemon_answers_a_start_whose_replay_socket_cannot_be_bound() {
    let max = mcp_harness::MAX_UNIX_SOCKET_PATH;
    let (_guard, root) = mcp_harness::short_root("ctsr");
    // The replay's socket is `<tmp>/session-manager/<pid>/<id>.sock`, so a
    // `<tmp>` as long as a socket address holds puts it past the limit
    // whatever the pid, while the daemon's own socket stays short.
    let tmp = dir_of_length(&root, max);
    let (mut daemon, socket) = start_daemon(&root, &tmp).await;
    let mut stream = UnixStream::connect(&socket).await.unwrap();

    stream
        .write_all(&frame(&start_replay_request(7, MISSING_REPLAY_SERVER)))
        .await
        .unwrap();
    let response = response_to(&mut stream, "ct/start-replay").await;
    assert_eq!(response.get("request_seq").and_then(Value::as_i64), Some(7));
    let message = refusal_message(&response);
    let replay_dir = tmp.join("session-manager");
    assert!(
        message.contains(&replay_dir.display().to_string())
            && message.contains("sun_path")
            && message.contains(&format!("the {max} a socket address holds")),
        "the refusal does not name the socket path and the limit: {message}"
    );

    // The control: the daemon still dispatches after the refusal.
    stream
        .write_all(&frame(
            &json!({"type": "request", "seq": 8, "command": "ct/ping"}),
        ))
        .await
        .unwrap();
    let ping = response_to(&mut stream, "ct/ping").await;
    assert_eq!(
        ping.get("success").and_then(Value::as_bool),
        Some(true),
        "{ping}"
    );

    mcp_harness::shutdown_daemon(&socket, &mut daemon).await;
}

#[tokio::test]
async fn the_daemon_answers_a_start_whose_replay_command_cannot_run() {
    let (_guard, root) = mcp_harness::short_root("ctsr");
    let tmp = root.join("tmp");
    fs::create_dir_all(&tmp).unwrap();
    let (mut daemon, socket) = start_daemon(&root, &tmp).await;
    let mut stream = UnixStream::connect(&socket).await.unwrap();

    stream
        .write_all(&frame(&start_replay_request(3, MISSING_REPLAY_SERVER)))
        .await
        .unwrap();
    let response = response_to(&mut stream, "ct/start-replay").await;
    assert_eq!(response.get("request_seq").and_then(Value::as_i64), Some(3));
    let message = refusal_message(&response);
    assert!(
        message.contains(MISSING_REPLAY_SERVER),
        "the refusal does not name the command that could not run: {message}"
    );

    stream
        .write_all(&frame(
            &json!({"type": "request", "seq": 4, "command": "ct/ping"}),
        ))
        .await
        .unwrap();
    let ping = response_to(&mut stream, "ct/ping").await;
    assert_eq!(
        ping.get("success").and_then(Value::as_bool),
        Some(true),
        "{ping}"
    );

    mcp_harness::shutdown_daemon(&socket, &mut daemon).await;
}

#[tokio::test]
async fn the_daemon_answers_a_start_whose_replay_exits_before_it_connects() {
    let (_guard, root) = mcp_harness::short_root("ctsr");
    let tmp = root.join("tmp");
    fs::create_dir_all(&tmp).unwrap();
    let (mut daemon, socket) = start_daemon(&root, &tmp).await;
    let mut stream = UnixStream::connect(&socket).await.unwrap();
    // `false(1)`: POSIX, on every host, and it exits 1 without connecting.
    let false_utility = false_utility();
    let exits_at_once = false_utility.to_str().expect("a UTF-8 path to false(1)");

    stream
        .write_all(&frame(&start_replay_request(5, exits_at_once)))
        .await
        .unwrap();
    let response = response_to(&mut stream, "ct/start-replay").await;
    assert_eq!(response.get("request_seq").and_then(Value::as_i64), Some(5));
    let message = refusal_message(&response);
    assert!(
        message.contains(exits_at_once)
            && message.contains("exited")
            && message.contains("before it connected"),
        "the refusal does not say the replay exited before it connected: {message}"
    );

    stream
        .write_all(&frame(
            &json!({"type": "request", "seq": 6, "command": "ct/ping"}),
        ))
        .await
        .unwrap();
    let ping = response_to(&mut stream, "ct/ping").await;
    assert_eq!(
        ping.get("success").and_then(Value::as_bool),
        Some(true),
        "{ping}"
    );

    mcp_harness::shutdown_daemon(&socket, &mut daemon).await;
}

#[tokio::test]
async fn the_single_client_session_manager_answers_a_start_whose_replay_command_cannot_run() {
    // The session manager the GUI's main process starts: no arguments, one
    // connection, on `<tmp>/session-manager/<its pid>.sock`.
    let (_guard, root) = mcp_harness::short_root("ctsr");
    let tmp = root.join("tmp");
    fs::create_dir_all(&tmp).unwrap();
    let stderr_log = root.join("session-manager.stderr");
    let mut manager = Command::new(mcp_harness::server_binary())
        .env("CODETRACER_TMP_PATH", &tmp)
        .env("CODETRACER_HOME", root.join("home"))
        .env("TMPDIR", &root)
        .stdout(Stdio::null())
        .stderr(fs::File::create(&stderr_log).unwrap())
        .kill_on_drop(true)
        .spawn()
        .expect("start the session manager");
    let pid = manager.id().expect("the session manager's pid");
    let socket = tmp.join("session-manager").join(format!("{pid}.sock"));
    mcp_harness::wait_for_daemon_socket(&mut manager, &socket, &stderr_log).await;
    let mut stream = UnixStream::connect(&socket).await.unwrap();

    stream
        .write_all(&frame(&start_replay_request(1, MISSING_REPLAY_SERVER)))
        .await
        .unwrap();
    let response = response_to(&mut stream, "ct/start-replay").await;
    let message = refusal_message(&response);
    assert!(
        message.contains(MISSING_REPLAY_SERVER),
        "the refusal does not name the command that could not run: {message}"
    );

    let _ = manager.start_kill();
    let _ = manager.wait().await;
}

/// The `false(1)` utility, found as a shell finds it: the first executable
/// `false` in the absolute directories of `PATH`, then `/usr/bin/false` and
/// `/bin/false`. POSIX specifies the utility, not where it is installed:
/// NixOS has neither of those two paths and puts `false` on `PATH` from the
/// Nix store, so a fixed list of paths made this test unrunnable there.
fn false_utility() -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let on_path = std::env::var_os("PATH")
        .map(|path| std::env::split_paths(&path).collect::<Vec<_>>())
        .unwrap_or_default();
    on_path
        .into_iter()
        // A relative entry would be resolved against the working directory.
        .filter(|dir| dir.is_absolute())
        .map(|dir| dir.join("false"))
        .chain([PathBuf::from("/usr/bin/false"), PathBuf::from("/bin/false")])
        .find(|candidate| {
            fs::metadata(candidate)
                .map(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
                .unwrap_or(false)
        })
        .expect("false(1): no executable `false` on PATH, at /usr/bin/false or at /bin/false")
}
