//! `read_source_file` serves only the files a recording carries.
//!
//! The MCP tool's `file_path` argument is chosen by the agent, and so by
//! anything the agent has read.  Before this test the fallback that serves
//! the tool read any absolute path that existed on the host, and joined a
//! relative path onto `files/`, the recorded working directory and the trace
//! directory's parent without rejecting `..`, so a request could name any
//! file the server's user can read.  This test drives the real server over
//! stdio and asks for:
//!
//! * an absolute host path outside the recording (the file exists and the
//!   test reads it first, so a refusal is not a missing file);
//! * relative paths with `..` that climb out of `files/`, out of the
//!   recorded working directory, and back into a listed file;
//! * a relative path that is not in the source list but lies beside the
//!   trace directory, which the old parent-directory lookup used to find;
//! * a symlink planted under `files/` that points out of it, to a file and
//!   to a directory; the embedded copy is opened component by component
//!   without following any symlink below `files/`.
//!
//! Each must come back as an MCP tool error reporting the file as not in the
//! recording, without the host file's content.  The server runs with
//! `--allow-host-source-reads`, the setting that reads the most, so the
//! refusals hold even where listed host files are served.  As the negative
//! control, a source the recording lists comes back byte-exact by its
//! absolute path and by its path relative to the recorded working directory,
//! and a source carried only as an embedded `files/` copy comes back
//! byte-exact too.
//!
//! The second test, `t_mcp_read_source_file_host_read_needs_opt_in`, is the
//! rule for the listed files themselves.  The
//! source list is recording content, so a recording can list a host file
//! outside its recorded working directory, here a stand-in for a credentials
//! file.  Without `--allow-host-source-reads`, the setting a sandboxed
//! agent's MCP configuration leaves off, a listed file the recording carries
//! no copy of is refused as not embedded, and a listed file it does carry a
//! copy of is served from the copy, not from the host.  With the option the
//! listed files are served from their recorded locations.  In both runs the
//! daemon's `ct/py-read-source` is checked to receive the resolved location
//! and never the requested path.
//!
//! ## What is real, and the one thing that is not a recorder
//!
//! The MCP server (`trace mcp`), the daemon and the `replay-server` it starts
//! are the production binaries, talking over their real stdio and socket
//! transports.  Nothing is mocked.  The recording is written by the
//! production pure-Rust CTFS writer (`codetracer_trace_writer`, the writer
//! the browser recorder uses) instead of a language recorder, so the test
//! needs no interpreter toolchain; the daemon and `replay-server` open it as
//! they open any recording.
//!
//! What the daemon is handed is observed by a byte relay on the daemon
//! socket: the MCP server connects to the relay, the relay forwards every
//! byte both ways to the real daemon unchanged and keeps a copy of what the
//! MCP server sent.  It answers nothing itself, so it is a tap, not a
//! stand-in for the daemon.
//!
//! A missing `replay-server` fails the test.  It is never a skip.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

#[path = "support/mcp_harness.rs"]
mod mcp_harness;

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use mcp_harness::*;
use serde_json::json;
use tokio::io::AsyncWriteExt;

/// The content of the host file outside the recording.  Its absence from
/// every refusal shows the server did not read it.
const HOST_SECRET: &str = "host-only-content: not a recorded source\n";
/// The listed source, read at its recorded location.
const APP_SOURCE: &str =
    "def main():\n    total = 0\n    for i in range(3):\n        total += i\n    return total\n";
/// The source carried only as an embedded `files/` copy.
const EMBEDDED_SOURCE: &str = "def helper(n):\n    return n * 2\n";
/// A host file a recording lists outside its recorded working directory,
/// standing in for a credentials file.
const HOST_CREDENTIALS: &str = "aws_secret_access_key = host-only-credential\n";
/// What lies on the host at the location of a listed file the recording
/// also carries a copy of; it differs from the copy, so the test can tell
/// which one was served.
const HELPER_ON_HOST: &str = "def helper(n):\n    return 'the host file, not the copy'\n";

#[tokio::test]
async fn t_mcp_read_source_file_confined_to_recording() {
    let replay_server = replay_server();
    let server = server_binary();

    let (_root, root_path) = short_root("ct-mcp-src-");

    // Layout:
    //   <root>/secret.txt              host file outside the recording
    //   <root>/project/app.py          the recorded source (recorded workdir: project/)
    //   <root>/trace/trace.ct          the recording
    //   <root>/trace/files/<helper>    an embedded copy only
    //   <root>/trace/files/link.txt    symlink to secret.txt
    //   <root>/trace/files/escape      directory symlink to <root>
    let secret = root_path.join("secret.txt");
    std::fs::write(&secret, HOST_SECRET).unwrap();
    let workdir = root_path.join("project");
    std::fs::create_dir_all(&workdir).unwrap();
    let app = workdir.join("app.py");
    std::fs::write(&app, APP_SOURCE).unwrap();
    let trace_dir = root_path.join("trace");
    std::fs::create_dir_all(&trace_dir).unwrap();
    write_recording(&trace_dir, &workdir, &app, &[]);
    let helper = root_path.join("lib/helper.py");
    let embedded = trace_dir.join("files").join(without_root(&helper));
    std::fs::create_dir_all(embedded.parent().unwrap()).unwrap();
    std::fs::write(&embedded, EMBEDDED_SOURCE).unwrap();
    #[cfg(unix)]
    std::os::unix::fs::symlink(&secret, trace_dir.join("files/link.txt")).unwrap();
    #[cfg(unix)]
    std::os::unix::fs::symlink(&root_path, trace_dir.join("files/escape")).unwrap();

    // Vacuity guard: the host file the server must refuse exists and is
    // readable by this user, the user the server runs as.
    assert_eq!(
        std::fs::read_to_string(&secret).expect("the host file is readable"),
        HOST_SECRET
    );

    // The real daemon and `ct trace mcp`, here with the option that reads
    // the most: listed host files are served, and nothing else is.
    let (mut daemon, socket) = start_daemon(&server, &root_path, &replay_server).await;
    let mut mcp = start_mcp(&server, &root_path, &socket, &["--allow-host-source-reads"]).await;

    // The source list the server reports is the one the writer recorded.
    let listed = mcp
        .request(
            "tools/call",
            json!({"name": "list_source_files", "arguments": {"trace_path": trace_dir}}),
        )
        .await;
    let listed_text = listed["result"]["content"][0]["text"]
        .as_str()
        .unwrap_or_default();
    assert!(
        listed_text.lines().any(|l| Path::new(l) == app),
        "list_source_files should list {}, got: {listed}",
        app.display()
    );

    // Negative control: what the recording carries comes back byte-exact.
    let app_abs = app.to_str().unwrap();
    assert_eq!(
        mcp.read_source(&trace_dir, app_abs).await,
        Ok(APP_SOURCE.to_owned())
    );
    assert_eq!(
        mcp.read_source(&trace_dir, "app.py").await,
        Ok(APP_SOURCE.to_owned())
    );
    assert_eq!(
        mcp.read_source(&trace_dir, helper.to_str().unwrap()).await,
        Ok(EMBEDDED_SOURCE.to_owned())
    );

    // Everything outside the recording is refused, unread.
    let secret_abs = secret.to_str().unwrap().to_owned();
    let back_into_listed = format!("{}/../project/app.py", workdir.display());
    let mut refused = vec![
        // An absolute host path outside the recording.
        secret_abs,
        // `..` out of the recorded working directory, and out of `files/`.
        "../secret.txt".to_owned(),
        "../../secret.txt".to_owned(),
        // `..` back into a listed source is refused too: no `..` at all.
        back_into_listed,
        // Beside the trace directory, but not in the source list.
        "secret.txt".to_owned(),
    ];
    if cfg!(unix) {
        // A symlink planted under `files/`.
        refused.push("link.txt".to_owned());
        // A directory symlink planted under `files/`, by a relative and an
        // absolute-style name (the `files/` layout strips the root).
        refused.push("escape/secret.txt".to_owned());
        refused.push("/escape/secret.txt".to_owned());
    }
    // Every path is asked before judging, so one run reports each arm.
    let mut wrong = Vec::new();
    for path in &refused {
        match mcp.read_source(&trace_dir, path).await {
            Ok(text) => wrong.push(format!("{path}: served {text:?}")),
            Err(text) if text.contains(HOST_SECRET.trim_end()) => {
                wrong.push(format!(
                    "{path}: refused, but the error carries the host file: {text}"
                ));
            }
            Err(text) if !text.contains("not in the recording") => {
                wrong.push(format!(
                    "{path}: not refused as not in the recording: {text}"
                ));
            }
            Err(_) => {}
        }
    }
    assert!(
        wrong.is_empty(),
        "read_source_file reached outside the recording:\n{}",
        wrong.join("\n")
    );

    mcp.stop().await;
    shutdown_daemon(&socket, &mut daemon).await;
}

#[cfg(unix)]
#[tokio::test]
async fn t_mcp_read_source_file_host_read_needs_opt_in() {
    let replay_server = replay_server();
    let server = server_binary();
    let (_root, root) = short_root("ct-mcp-host-");

    // Layout:
    //   <root>/host/credentials           listed, outside the recorded workdir, no copy
    //   <root>/project/app.py             the recorded program (workdir: project/), no copy
    //   <root>/lib/helper.py              listed; the host file differs from its copy
    //   <root>/trace/trace.ct             the recording
    //   <root>/trace/files/<lib/helper.py> the embedded copy
    let credentials = root.join("host/credentials");
    std::fs::create_dir_all(credentials.parent().unwrap()).unwrap();
    std::fs::write(&credentials, HOST_CREDENTIALS).unwrap();
    let workdir = root.join("project");
    std::fs::create_dir_all(&workdir).unwrap();
    let app = workdir.join("app.py");
    std::fs::write(&app, APP_SOURCE).unwrap();
    let helper = root.join("lib/helper.py");
    std::fs::create_dir_all(helper.parent().unwrap()).unwrap();
    std::fs::write(&helper, HELPER_ON_HOST).unwrap();
    let trace_dir = root.join("trace");
    std::fs::create_dir_all(&trace_dir).unwrap();
    write_recording(&trace_dir, &workdir, &app, &[&credentials, &helper]);
    let embedded = trace_dir.join("files").join(without_root(&helper));
    std::fs::create_dir_all(embedded.parent().unwrap()).unwrap();
    std::fs::write(&embedded, EMBEDDED_SOURCE).unwrap();

    // Vacuity guard: every host file the server must not read is readable by
    // this user, the user the server runs as, and the credentials file lies
    // outside the recorded working directory.
    for (path, content) in [
        (&credentials, HOST_CREDENTIALS),
        (&app, APP_SOURCE),
        (&helper, HELPER_ON_HOST),
    ] {
        assert_eq!(std::fs::read_to_string(path).unwrap(), content);
    }
    assert!(!credentials.starts_with(&workdir));

    // The real daemon, reached through the relay that records what the MCP
    // server sends it.
    let (mut daemon, daemon_socket) = start_daemon(&server, &root, &replay_server).await;
    let relay_socket = root.join("relay.sock");
    let (sent, relay) = start_relay(&relay_socket, daemon_socket.clone());

    let credentials_abs = credentials.to_str().unwrap();
    let app_abs = app.to_str().unwrap();
    let helper_abs = helper.to_str().unwrap();
    let embedded_location = embedded.canonicalize().unwrap();
    let mut wrong = Vec::new();

    // Without the option, the MCP configuration of a sandboxed agent.
    let mut mcp = start_mcp(&server, &root, &relay_socket, &[]).await;
    let listed = mcp
        .request(
            "tools/call",
            json!({"name": "list_source_files", "arguments": {"trace_path": trace_dir}}),
        )
        .await;
    let listed_text = listed["result"]["content"][0]["text"]
        .as_str()
        .unwrap_or_default()
        .to_owned();
    for path in [&credentials, &app, &helper] {
        assert!(
            listed_text.lines().any(|l| Path::new(l) == path.as_path()),
            "list_source_files should list {}, got: {listed}",
            path.display()
        );
    }
    for path in [credentials_abs, "app.py", app_abs] {
        match mcp.read_source(&trace_dir, path).await {
            Ok(text) => wrong.push(format!("without the option, {path}: served {text:?}")),
            Err(text)
                if text.contains(HOST_CREDENTIALS.trim_end())
                    || text.contains(APP_SOURCE.lines().next().unwrap()) =>
            {
                wrong.push(format!(
                    "without the option, {path}: refused, but the error carries the file: {text}"
                ));
            }
            Err(text) if !text.contains("not embedded in the recording") => {
                wrong.push(format!(
                    "without the option, {path}: not refused as not embedded: {text}"
                ));
            }
            Err(_) => {}
        }
    }
    // Negative control: a listed file the recording carries a copy of is
    // served, from the copy.
    let served = mcp.read_source(&trace_dir, helper_abs).await;
    if served != Ok(EMBEDDED_SOURCE.to_owned()) {
        wrong.push(format!(
            "without the option, {helper_abs}: expected the embedded copy, got {served:?}"
        ));
    }
    // The `trace:///<trace>/source/<file>` resource holds the same rule.
    match mcp.read_source_resource(&trace_dir, "app.py").await {
        Err(text) if text.contains("not embedded in the recording") => {}
        other => wrong.push(format!(
            "without the option, the app.py resource: expected a refusal as not embedded, got {other:?}"
        )),
    }
    mcp.stop().await;
    let handed_without = take_read_source_paths(&sent);

    // With the option, the listed files are read where they were recorded,
    // and the embedded copy still wins over the host file.
    let mut mcp = start_mcp(
        &server,
        &root,
        &relay_socket,
        &["--allow-host-source-reads"],
    )
    .await;
    for (path, expected) in [
        (credentials_abs, HOST_CREDENTIALS),
        ("app.py", APP_SOURCE),
        (helper_abs, EMBEDDED_SOURCE),
    ] {
        let served = mcp.read_source(&trace_dir, path).await;
        if served != Ok(expected.to_owned()) {
            wrong.push(format!(
                "with the option, {path}: expected {expected:?}, got {served:?}"
            ));
        }
    }
    let served = mcp.read_source_resource(&trace_dir, "app.py").await;
    if served != Ok(APP_SOURCE.to_owned()) {
        wrong.push(format!(
            "with the option, the app.py resource: expected {APP_SOURCE:?}, got {served:?}"
        ));
    }
    mcp.stop().await;
    let handed_with = take_read_source_paths(&sent);

    // The daemon is handed the resolved location of each served file, and
    // nothing for a refused one.  "app.py" was requested; its location under
    // the recorded working directory is what the daemon receives.
    let expected_without = vec![embedded_location.clone()];
    if handed_without != expected_without {
        wrong.push(format!(
            "without the option, ct/py-read-source was handed {handed_without:?}, \
             expected {expected_without:?}"
        ));
    }
    let expected_with = vec![
        credentials.clone(),
        app.clone(),
        embedded_location.clone(),
        app.clone(),
    ];
    if handed_with != expected_with {
        wrong.push(format!(
            "with the option, ct/py-read-source was handed {handed_with:?}, \
             expected {expected_with:?}"
        ));
    }

    relay.abort();
    shutdown_daemon(&daemon_socket, &mut daemon).await;
    assert!(
        wrong.is_empty(),
        "read_source_file's host-read rule does not hold:\n{}",
        wrong.join("\n")
    );
}

/// Every connection the relay carried, each with the bytes the MCP server
/// sent on it, in the order the connections were accepted.
#[cfg(unix)]
type Sent = Arc<Mutex<Vec<Vec<u8>>>>;

/// Listen on `relay_socket` and carry each connection to the real daemon at
/// `daemon_socket`, both directions unchanged, keeping a copy of what the
/// client sent.  The relay answers nothing itself.
#[cfg(unix)]
fn start_relay(relay_socket: &Path, daemon_socket: PathBuf) -> (Sent, tokio::task::JoinHandle<()>) {
    use tokio::io::AsyncReadExt;
    let listener = tokio::net::UnixListener::bind(relay_socket).expect("bind the relay socket");
    let sent: Sent = Arc::default();
    let tap = sent.clone();
    let task = tokio::spawn(async move {
        while let Ok((client, _)) = listener.accept().await {
            let slot = {
                let mut connections = tap.lock().unwrap();
                connections.push(Vec::new());
                connections.len() - 1
            };
            let tap = tap.clone();
            let daemon_socket = daemon_socket.clone();
            tokio::spawn(async move {
                let Ok(upstream) = tokio::net::UnixStream::connect(&daemon_socket).await else {
                    return;
                };
                let (mut client_read, mut client_write) = client.into_split();
                let (mut daemon_read, mut daemon_write) = upstream.into_split();
                let to_daemon = async {
                    let mut buf = vec![0u8; 16 * 1024];
                    loop {
                        let n = match client_read.read(&mut buf).await {
                            Ok(0) | Err(_) => break,
                            Ok(n) => n,
                        };
                        tap.lock().unwrap()[slot].extend_from_slice(&buf[..n]);
                        if daemon_write.write_all(&buf[..n]).await.is_err() {
                            break;
                        }
                    }
                    let _ = daemon_write.shutdown().await;
                };
                let to_client = async {
                    let _ = tokio::io::copy(&mut daemon_read, &mut client_write).await;
                    let _ = client_write.shutdown().await;
                };
                tokio::join!(to_daemon, to_client);
            });
        }
    });
    (sent, task)
}

/// The `path` argument of every `ct/py-read-source` request the relay has
/// carried since the last call, in order; the record is then cleared.
#[cfg(unix)]
fn take_read_source_paths(sent: &Sent) -> Vec<PathBuf> {
    let connections = std::mem::take(&mut *sent.lock().unwrap());
    let mut paths = Vec::new();
    for bytes in connections {
        for msg in dap_messages(&bytes) {
            if msg["command"] == "ct/py-read-source" {
                paths.push(PathBuf::from(
                    msg["arguments"]["path"]
                        .as_str()
                        .expect("ct/py-read-source carries a string path"),
                ));
            }
        }
    }
    paths
}
