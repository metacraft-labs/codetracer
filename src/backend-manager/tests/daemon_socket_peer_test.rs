//! The daemon's socket is its owner's alone, and the daemon answers only a
//! peer that runs as the same user.
//!
//! The daemon runs scripts and opens recordings for whoever talks to it, so
//! a process of another user must not reach it.  The socket file's mode is
//! the first check (owner read and write only); the daemon also checks each
//! connection's peer credentials (`SO_PEERCRED`), which holds where the mode
//! does not (a socket path in a shared directory, a mode changed later).
//!
//! `t_mcp_daemon_socket_is_its_owners_alone` runs anywhere.
//! `t_mcp_daemon_answers_no_peer_of_another_user` needs a second user: it
//! connects as `nobody` through `sudo -n -u nobody`, so it is `#[ignore]`d in
//! the default run (which cannot switch users) and is run explicitly with
//! `--ignored` on a host that can; it fails, never skips, when `sudo` is not
//! available there.  Its vacuity guard is the same client run as the
//! daemon's own user, which is answered.
//!
//! What is real: the daemon and the kernel's credential passing.  The
//! client is a few lines of Python speaking the daemon's DAP framing.  No
//! component is mocked.

#![cfg(target_os = "linux")]
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

#[path = "support/mcp_harness.rs"]
mod mcp_harness;

use std::os::unix::fs::{FileTypeExt, PermissionsExt};
use std::path::Path;
use std::process::Command;

use mcp_harness::*;

/// Sends `ct/ping` and prints `ANSWERED` with the response, or `NO-ANSWER`.
const PING: &str = r#"import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(5)
s.connect(sys.argv[1])
body = b'{"type":"request","command":"ct/ping","seq":5}'
s.sendall(b"Content-Length: %d\r\n\r\n" % len(body) + body)
data = b""
try:
    while b"pong" not in data:
        chunk = s.recv(4096)
        if not chunk:
            break
        data += chunk
except OSError as e:
    print("ERROR", e)
print("ANSWERED" if b"pong" in data else "NO-ANSWER", data[:200])
"#;

/// Everything the files under `dir` hold, concatenated.
fn logs_under(dir: &Path) -> String {
    let mut out = String::new();
    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                out.push_str(&logs_under(&path));
            } else {
                out.push_str(&std::fs::read_to_string(&path).unwrap_or_default());
            }
        }
    }
    out
}

fn python3() -> String {
    let path = std::env::var_os("PATH").unwrap();
    std::env::split_paths(&path)
        .map(|d| d.join("python3"))
        .find(|p| p.is_file())
        .expect("python3 on PATH")
        .canonicalize()
        .unwrap()
        .display()
        .to_string()
}

fn ping(socket: &Path, sudo_user: Option<&str>) -> String {
    let python = python3();
    let mut cmd = match sudo_user {
        Some(user) => {
            let mut c = Command::new("sudo");
            c.args(["-n", "-u", user, &python]);
            c
        }
        None => Command::new(&python),
    };
    let out = cmd
        .args(["-I", "-c", PING])
        .arg(socket)
        .output()
        .expect("run the client");
    format!(
        "{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    )
}

#[tokio::test(flavor = "multi_thread")]
async fn t_mcp_daemon_socket_is_its_owners_alone() {
    let (_guard, root) = short_root("ct-socket-");
    let server = server_binary();
    let (mut daemon, socket) = start_daemon(&server, &root, &replay_server_for(&server)).await;
    let meta = std::fs::metadata(&socket).unwrap();
    assert!(meta.file_type().is_socket());
    assert_eq!(
        meta.permissions().mode() & 0o777,
        0o600,
        "the socket's mode"
    );
    let answer = ping(&socket, None);
    assert!(answer.contains("ANSWERED"), "{answer}");
    shutdown_daemon(&socket, &mut daemon).await;
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs a second user: run with --ignored where `sudo -n -u nobody` works"]
async fn t_mcp_daemon_answers_no_peer_of_another_user() {
    let (_guard, root) = short_root("ct-peer-");
    let server = server_binary();
    // The daemon logs under CODETRACER_HOME's state area: the home the
    // harness gives it.
    let home = daemon_home(&root);
    let (mut daemon, socket) = start_daemon(&server, &root, &replay_server_for(&server)).await;
    // Open the path to everyone, so only the peer check stands between
    // another user and the daemon.
    for dir in [root.as_path(), socket.parent().unwrap()] {
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o666)).unwrap();

    let sudo_ok = Command::new("sudo")
        .args(["-n", "-u", "nobody", "true"])
        .status()
        .is_ok_and(|s| s.success());
    assert!(
        sudo_ok,
        "this test needs `sudo -n -u nobody` to run a client as another user"
    );

    let theirs = ping(&socket, Some("nobody"));
    let ours = ping(&socket, None);
    shutdown_daemon(&socket, &mut daemon).await;
    let log = logs_under(&home);

    assert!(
        theirs.contains("NO-ANSWER"),
        "another user was answered: {theirs}"
    );
    assert!(
        ours.contains("ANSWERED"),
        "vacuity guard: the owner was not answered: {ours}"
    );
    assert!(
        log.contains("refused a connection: its peer runs as uid"),
        "the daemon did not log the refusal: {log}"
    );
}
