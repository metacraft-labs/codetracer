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

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use codetracer_trace_types::{Line, NONE_TYPE_ID, TypeKind, ValueRecord};
use codetracer_trace_writer::ctfs_writer::CtfsTraceWriter;
use codetracer_trace_writer::trace_writer::TraceWriter;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::time::{sleep, timeout};

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

/// The `session-manager` (formerly `backend-manager`) binary next to this
/// test binary, the binary `ct trace mcp` runs.
fn server_binary() -> PathBuf {
    let mut dir = std::env::current_exe().expect("test binary path");
    dir.pop();
    if dir.ends_with("deps") {
        dir.pop();
    }
    for name in ["session-manager", "backend-manager"] {
        let candidate = dir.join(format!("{name}{}", std::env::consts::EXE_SUFFIX));
        if candidate.is_file() {
            return candidate;
        }
    }
    panic!("no session-manager binary next to {}", dir.display());
}

/// The `replay-server` the daemon starts for the recording: the one named
/// by `CODETRACER_REPLAY_SERVER_CMD`, else the one built beside this test,
/// else the sibling db-backend crate's build.  Missing is a failure.
fn replay_server() -> PathBuf {
    if let Ok(cmd) = std::env::var("CODETRACER_REPLAY_SERVER_CMD") {
        let path = PathBuf::from(cmd);
        assert!(
            path.is_file(),
            "CODETRACER_REPLAY_SERVER_CMD={} is not a file",
            path.display()
        );
        return path;
    }
    let exe = std::env::consts::EXE_SUFFIX;
    let beside = server_binary().with_file_name(format!("replay-server{exe}"));
    if beside.is_file() {
        return beside;
    }
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    for profile in ["release", "debug"] {
        let candidate =
            manifest_dir.join(format!("../db-backend/target/{profile}/replay-server{exe}"));
        if candidate.is_file() {
            return candidate.canonicalize().unwrap_or(candidate);
        }
    }
    panic!(
        "replay-server was not found (CODETRACER_REPLAY_SERVER_CMD, beside the test \
         binary, or src/db-backend/target/{{release,debug}}); build it first"
    );
}

/// Write a recording of `source` into `trace_dir/trace.ct` with the
/// production CTFS writer, `workdir` as its recorded working directory.
/// `also_listed` are added to its source list, as a recorder adds every
/// file the program touched as source.
fn write_recording(trace_dir: &Path, workdir: &Path, source: &Path, also_listed: &[&Path]) {
    let mut writer = CtfsTraceWriter::new("app.py", &[]);
    TraceWriter::set_workdir(&mut writer, workdir);
    TraceWriter::begin_writing_trace_events(&mut writer, &trace_dir.join("trace"))
        .expect("begin writing the recording");
    TraceWriter::start(&mut writer, source, Line(1));
    for path in also_listed {
        TraceWriter::ensure_path_id(&mut writer, path);
    }
    let int_type = TraceWriter::ensure_type_id(&mut writer, TypeKind::Int, "int");
    let main_fn = TraceWriter::ensure_function_id(&mut writer, "main", source, Line(1));
    TraceWriter::register_call(&mut writer, main_fn, vec![]);
    for (line, total) in [(2, 0), (4, 0), (4, 1), (4, 3), (5, 3)] {
        TraceWriter::register_step(&mut writer, source, Line(line));
        TraceWriter::register_variable_with_full_value(
            &mut writer,
            "total",
            ValueRecord::Int {
                i: total,
                type_id: int_type,
            },
        );
    }
    TraceWriter::register_return(
        &mut writer,
        ValueRecord::None {
            type_id: NONE_TYPE_ID,
        },
    );
    TraceWriter::finish_writing_trace_events(&mut writer).expect("finish the recording");
    TraceWriter::close(&mut writer).expect("close the recording");
    assert!(
        trace_dir.join("trace.ct").is_file(),
        "the writer produced no trace.ct"
    );
}

/// Strip the root of an absolute path, the layout `files/` mirrors.
fn without_root(path: &Path) -> PathBuf {
    use std::path::Component;
    path.components()
        .filter(|c| !matches!(c, Component::Prefix(_) | Component::RootDir))
        .collect()
}

struct Mcp {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    next_id: i64,
}

impl Mcp {
    async fn request(&mut self, method: &str, params: Value) -> Value {
        self.next_id += 1;
        let id = self.next_id;
        let line = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        self.stdin
            .write_all(format!("{line}\n").as_bytes())
            .await
            .expect("write to the MCP server");
        self.stdin
            .flush()
            .await
            .expect("flush the MCP server's stdin");
        loop {
            let mut buf = String::new();
            let n = timeout(Duration::from_secs(90), self.stdout.read_line(&mut buf))
                .await
                .expect("the MCP server answered in time")
                .expect("read from the MCP server");
            assert!(n > 0, "the MCP server closed stdout");
            let msg: Value = serde_json::from_str(buf.trim()).expect("a JSON-RPC line");
            if msg.get("id") == Some(&json!(id)) {
                return msg;
            }
        }
    }

    /// Close the server's stdin and wait for it to exit.
    async fn stop(mut self) {
        drop(self.stdin);
        let _ = timeout(Duration::from_secs(5), self.child.wait()).await;
        let _ = self.child.kill().await;
    }

    /// The `trace:///<trace>/source/<file_path>` resource, after loading the
    /// trace with `trace_info` (the resource serves loaded traces only):
    /// `Ok(text)` for its content, `Err(message)` for a JSON-RPC error.
    async fn read_source_resource(
        &mut self,
        trace_dir: &Path,
        file_path: &str,
    ) -> Result<String, String> {
        let info = self
            .request(
                "tools/call",
                json!({"name": "trace_info", "arguments": {"trace_path": trace_dir}}),
            )
            .await;
        assert!(
            info["result"].get("isError") != Some(&Value::Bool(true)),
            "trace_info failed: {info}"
        );
        let uri = format!("trace://{}/source/{file_path}", trace_dir.display());
        let resp = self.request("resources/read", json!({"uri": uri})).await;
        if let Some(error) = resp.get("error") {
            return Err(error["message"].as_str().unwrap_or_default().to_owned());
        }
        Ok(resp["result"]["contents"][0]["text"]
            .as_str()
            .unwrap_or_else(|| panic!("resources/read {uri} has no text: {resp}"))
            .to_owned())
    }

    /// `read_source_file` for `file_path`: `Ok(text)` for a result,
    /// `Err(text)` for a tool error.
    async fn read_source(&mut self, trace_dir: &Path, file_path: &str) -> Result<String, String> {
        let resp = self
            .request(
                "tools/call",
                json!({
                    "name": "read_source_file",
                    "arguments": {"trace_path": trace_dir, "file_path": file_path},
                }),
            )
            .await;
        let result = resp
            .get("result")
            .unwrap_or_else(|| panic!("read_source_file({file_path}) gave no result: {resp}"));
        let text = result["content"][0]["text"]
            .as_str()
            .unwrap_or_else(|| panic!("read_source_file({file_path}) result has no text: {resp}"))
            .to_owned();
        if result.get("isError") == Some(&Value::Bool(true)) {
            Err(text)
        } else {
            Ok(text)
        }
    }
}

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
        let mut rest = bytes.as_slice();
        // DAP framing: `Content-Length: N\r\n\r\n` then N bytes of JSON.
        while let Some(header_end) = rest.windows(4).position(|w| w == b"\r\n\r\n") {
            let header = std::str::from_utf8(&rest[..header_end]).expect("a DAP header");
            let length: usize = header
                .lines()
                .find_map(|l| l.strip_prefix("Content-Length:"))
                .expect("a Content-Length header")
                .trim()
                .parse()
                .expect("a Content-Length value");
            let body = &rest[header_end + 4..header_end + 4 + length];
            rest = &rest[header_end + 4 + length..];
            let msg: Value = serde_json::from_slice(body).expect("a DAP message");
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

/// A fresh test directory with a short canonical path, so the daemon's
/// socket path fits in `sun_path`.
fn short_root(prefix: &str) -> (tempfile::TempDir, PathBuf) {
    let root = tempfile::Builder::new()
        .prefix(prefix)
        .tempdir_in(if cfg!(unix) {
            PathBuf::from("/tmp")
        } else {
            std::env::temp_dir()
        })
        .expect("test directory");
    let path = root
        .path()
        .canonicalize()
        .expect("canonical test directory");
    (root, path)
}

/// The real daemon, with its own socket under `root`, starting the real
/// `replay-server`.  Returns it and its socket once the socket exists.
async fn start_daemon(server: &Path, root: &Path, replay_server: &Path) -> (Child, PathBuf) {
    let daemon_dir = root.join("codetracer");
    std::fs::create_dir_all(&daemon_dir).unwrap();
    let socket = daemon_dir.join(if cfg!(windows) {
        "daemon.port"
    } else {
        "daemon.sock"
    });
    let daemon = Command::new(server)
        .args(["daemon", "start"])
        .env("TMPDIR", root)
        .env("CODETRACER_DAEMON_SOCKET", &socket)
        .env("CODETRACER_REPLAY_SERVER_CMD", replay_server)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .expect("start the daemon");
    let started = tokio::time::Instant::now();
    while !socket.exists() {
        assert!(
            started.elapsed() < Duration::from_secs(15),
            "the daemon socket never appeared"
        );
        sleep(Duration::from_millis(50)).await;
    }
    (daemon, socket)
}

/// `ct trace mcp <extra_args>` on stdio, pointed at the daemon socket
/// `socket`, initialized.
async fn start_mcp(server: &Path, root: &Path, socket: &Path, extra_args: &[&str]) -> Mcp {
    let mut child = Command::new(server)
        .args(["trace", "mcp"])
        .args(extra_args)
        .env("TMPDIR", root)
        .env("CODETRACER_DAEMON_SOCK", socket)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .expect("start trace mcp");
    let stdin = child.stdin.take().unwrap();
    let stdout = BufReader::new(child.stdout.take().unwrap());
    let mut mcp = Mcp {
        child,
        stdin,
        stdout,
        next_id: 0,
    };
    mcp.request(
        "initialize",
        json!({"protocolVersion": "2024-11-05", "clientInfo": {"name": "confinement-test", "version": "1"}}),
    )
    .await;
    mcp
}

/// Ask the daemon to shut down (it stops the replay-server it started), and
/// kill it if it does not exit in time.
async fn shutdown_daemon(socket: &Path, daemon: &mut Child) {
    let body = json!({"type": "request", "command": "ct/daemon-shutdown", "seq": 1}).to_string();
    let frame = format!("Content-Length: {}\r\n\r\n{body}", body.len());
    #[cfg(unix)]
    let stream = tokio::net::UnixStream::connect(socket).await;
    #[cfg(windows)]
    let stream = match std::fs::read_to_string(socket).map(|p| p.trim().parse::<u16>()) {
        Ok(Ok(port)) => tokio::net::TcpStream::connect(("127.0.0.1", port)).await,
        _ => Err(std::io::Error::other("no daemon port file")),
    };
    if let Ok(mut stream) = stream {
        let _ = stream.write_all(frame.as_bytes()).await;
    }
    if timeout(Duration::from_secs(5), daemon.wait())
        .await
        .is_err()
    {
        let _ = daemon.kill().await;
    }
}
