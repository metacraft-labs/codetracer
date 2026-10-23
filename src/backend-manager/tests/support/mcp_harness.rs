//! The parts of the MCP source-reading tests that drive the real binaries:
//! the `session-manager` (`ct trace mcp` and the daemon), the
//! `replay-server` the daemon starts, recordings written by the production
//! CTFS writer, and DAP framing.  Shared by
//! `mcp_read_source_file_confinement_test.rs` and
//! `mcp_host_source_reads_test.rs`; nothing here stands in for a component.

#![allow(dead_code, clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use codetracer_trace_types::{Line, NONE_TYPE_ID, TypeKind, ValueRecord};
use codetracer_trace_writer::ctfs_writer::CtfsTraceWriter;
use codetracer_trace_writer::trace_writer::TraceWriter;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::time::{sleep, timeout};

/// The `session-manager` (formerly `backend-manager`) binary next to this
/// test binary, the binary `ct trace mcp` runs.
pub fn server_binary() -> PathBuf {
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
pub fn replay_server() -> PathBuf {
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
pub fn write_recording(trace_dir: &Path, workdir: &Path, source: &Path, also_listed: &[&Path]) {
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
pub fn without_root(path: &Path) -> PathBuf {
    use std::path::Component;
    path.components()
        .filter(|c| !matches!(c, Component::Prefix(_) | Component::RootDir))
        .collect()
}

pub struct Mcp {
    pub child: Child,
    pub stdin: ChildStdin,
    pub stdout: BufReader<ChildStdout>,
    pub next_id: i64,
}

impl Mcp {
    pub async fn request(&mut self, method: &str, params: Value) -> Value {
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
    pub async fn stop(mut self) {
        drop(self.stdin);
        let _ = timeout(Duration::from_secs(5), self.child.wait()).await;
        let _ = self.child.kill().await;
    }

    /// The `trace:///<trace>/source/<file_path>` resource, after loading the
    /// trace with `trace_info` (the resource serves loaded traces only):
    /// `Ok(text)` for its content, `Err(message)` for a JSON-RPC error.
    pub async fn read_source_resource(
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

    /// `tools/call` of `name` with `arguments`: `Ok(text)` for a result,
    /// `Err(text)` for a tool error (`isError`), the text of its first
    /// content item either way.
    pub async fn call_tool(&mut self, name: &str, arguments: Value) -> Result<String, String> {
        let resp = self
            .request("tools/call", json!({"name": name, "arguments": arguments}))
            .await;
        let result = resp
            .get("result")
            .unwrap_or_else(|| panic!("{name} gave no result: {resp}"));
        let text = result["content"][0]["text"]
            .as_str()
            .unwrap_or_else(|| panic!("{name} result has no text: {resp}"))
            .to_owned();
        if result.get("isError") == Some(&Value::Bool(true)) {
            Err(text)
        } else {
            Ok(text)
        }
    }

    /// `read_source_file` for `file_path`: `Ok(text)` for a result,
    /// `Err(text)` for a tool error.
    pub async fn read_source(
        &mut self,
        trace_dir: &Path,
        file_path: &str,
    ) -> Result<String, String> {
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

/// A fresh test directory with a short canonical path, so the daemon's
/// socket path fits in `sun_path`.
pub fn short_root(prefix: &str) -> (tempfile::TempDir, PathBuf) {
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
pub async fn start_daemon(server: &Path, root: &Path, replay_server: &Path) -> (Child, PathBuf) {
    start_daemon_with_env(server, root, replay_server, &[]).await
}

/// [`start_daemon`] with extra environment for the daemon and the processes
/// it starts.
pub async fn start_daemon_with_env(
    server: &Path,
    root: &Path,
    replay_server: &Path,
    env: &[(&str, &OsStr)],
) -> (Child, PathBuf) {
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
        .envs(env.iter().map(|(k, v)| (*k, *v)))
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
pub async fn start_mcp(server: &Path, root: &Path, socket: &Path, extra_args: &[&str]) -> Mcp {
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
pub async fn shutdown_daemon(socket: &Path, daemon: &mut Child) {
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

/// The DAP messages in `bytes`, a stream of `Content-Length: N\r\n\r\n`
/// frames, in order.
pub fn dap_messages(bytes: &[u8]) -> Vec<Value> {
    let mut messages = Vec::new();
    let mut rest = bytes;
    while let Some(header_end) = rest.windows(4).position(|w| w == b"\r\n\r\n") {
        let header = std::str::from_utf8(&rest[..header_end]).expect("a DAP header");
        let length: usize = header
            .lines()
            .find_map(|l| l.strip_prefix("Content-Length:"))
            .expect("a Content-Length header")
            .trim()
            .parse()
            .expect("a Content-Length value");
        if rest.len() < header_end + 4 + length {
            break;
        }
        let body = &rest[header_end + 4..header_end + 4 + length];
        rest = &rest[header_end + 4 + length..];
        messages.push(serde_json::from_slice(body).expect("a DAP message"));
    }
    messages
}
