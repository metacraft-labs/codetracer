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
//! * a symlink planted under `files/` that points out of it.
//!
//! Each must come back as an MCP tool error reporting the file as not in the
//! recording, without the host file's content.  As the negative control, a
//! source the recording lists comes back byte-exact by its absolute path and
//! by its path relative to the recorded working directory, and a source
//! carried only as an embedded `files/` copy comes back byte-exact too.
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
//! A missing `replay-server` fails the test.  It is never a skip.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

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

/// The content of the host file outside the recording.  Its absence from
/// every refusal shows the server did not read it.
const HOST_SECRET: &str = "host-only-content: not a recorded source\n";
/// The listed source, read at its recorded location.
const APP_SOURCE: &str =
    "def main():\n    total = 0\n    for i in range(3):\n        total += i\n    return total\n";
/// The source carried only as an embedded `files/` copy.
const EMBEDDED_SOURCE: &str = "def helper(n):\n    return n * 2\n";

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
fn write_recording(trace_dir: &Path, workdir: &Path, source: &Path) {
    let mut writer = CtfsTraceWriter::new("app.py", &[]);
    TraceWriter::set_workdir(&mut writer, workdir);
    TraceWriter::begin_writing_trace_events(&mut writer, &trace_dir.join("trace"))
        .expect("begin writing the recording");
    TraceWriter::start(&mut writer, source, Line(1));
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

    // A short root keeps the daemon's socket path inside `sun_path`.
    let root = tempfile::Builder::new()
        .prefix("ct-mcp-src-")
        .tempdir_in(if cfg!(unix) {
            PathBuf::from("/tmp")
        } else {
            std::env::temp_dir()
        })
        .expect("test directory");
    let root_path = root
        .path()
        .canonicalize()
        .expect("canonical test directory");

    // Layout:
    //   <root>/secret.txt              host file outside the recording
    //   <root>/project/app.py          the recorded source (recorded workdir: project/)
    //   <root>/trace/trace.ct          the recording
    //   <root>/trace/files/<helper>    an embedded copy only
    //   <root>/trace/files/link.txt    symlink to secret.txt
    let secret = root_path.join("secret.txt");
    std::fs::write(&secret, HOST_SECRET).unwrap();
    let workdir = root_path.join("project");
    std::fs::create_dir_all(&workdir).unwrap();
    let app = workdir.join("app.py");
    std::fs::write(&app, APP_SOURCE).unwrap();
    let trace_dir = root_path.join("trace");
    std::fs::create_dir_all(&trace_dir).unwrap();
    write_recording(&trace_dir, &workdir, &app);
    let helper = root_path.join("lib/helper.py");
    let embedded = trace_dir.join("files").join(without_root(&helper));
    std::fs::create_dir_all(embedded.parent().unwrap()).unwrap();
    std::fs::write(&embedded, EMBEDDED_SOURCE).unwrap();
    #[cfg(unix)]
    std::os::unix::fs::symlink(&secret, trace_dir.join("files/link.txt")).unwrap();

    // Vacuity guard: the host file the server must refuse exists and is
    // readable by this user, the user the server runs as.
    assert_eq!(
        std::fs::read_to_string(&secret).expect("the host file is readable"),
        HOST_SECRET
    );

    // The real daemon, with its own socket, starting the real replay-server.
    let daemon_dir = root_path.join("codetracer");
    std::fs::create_dir_all(&daemon_dir).unwrap();
    let socket = daemon_dir.join(if cfg!(windows) {
        "daemon.port"
    } else {
        "daemon.sock"
    });
    let mut daemon = Command::new(&server)
        .args(["daemon", "start"])
        .env("TMPDIR", &root_path)
        .env("CODETRACER_DAEMON_SOCKET", &socket)
        .env("CODETRACER_REPLAY_SERVER_CMD", &replay_server)
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

    // `ct trace mcp` on stdio, pointed at that daemon.
    let mut child = Command::new(&server)
        .args(["trace", "mcp"])
        .env("TMPDIR", &root_path)
        .env("CODETRACER_DAEMON_SOCK", &socket)
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

    drop(mcp.stdin);
    let _ = timeout(Duration::from_secs(5), mcp.child.wait()).await;
    let _ = mcp.child.kill().await;
    shutdown_daemon(&socket, &mut daemon).await;
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
