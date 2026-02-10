//! Integration tests for the MCP server (Milestone M10).
//!
//! Each test:
//! - Uses a unique temporary directory to avoid collisions.
//! - Starts a daemon with MockDapBackend.
//! - Opens a trace on the daemon.
//! - Spawns `backend-manager trace mcp` with CODETRACER_DAEMON_SOCK pointing
//!   to the daemon socket.
//! - Writes JSON-RPC messages to the MCP server's stdin.
//! - Reads JSON-RPC responses from its stdout.
//! - Verifies the responses match MCP protocol expectations.
//!
//! Test naming follows the V-M10-* verification matrix.

use std::io::Write as IoWrite;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::process::Command;
use tokio::time::{sleep, timeout};

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// Returns the path to the compiled `backend-manager` binary.
fn binary_path() -> PathBuf {
    let mut path = std::env::current_exe().expect("cannot determine test binary path");
    path.pop();
    if path.ends_with("deps") {
        path.pop();
    }
    path.push("backend-manager");
    path
}

/// Creates a unique temp directory for the test.
fn setup_test_dir(test_name: &str) -> (PathBuf, PathBuf) {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};

    let mut hasher = DefaultHasher::new();
    test_name.hash(&mut hasher);
    let hash = hasher.finish();

    let dir = PathBuf::from("/tmp")
        .join("ct-mcp")
        .join(format!("{}-{:x}", std::process::id(), hash));
    std::fs::create_dir_all(&dir).expect("cannot create test temp dir");
    let log_path = dir.join("test.log");
    (dir, log_path)
}

/// Appends a line to the test log file.
fn log_line(log_path: &Path, line: &str) {
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_path)
        .expect("cannot open log file");
    writeln!(f, "{line}").expect("cannot write to log file");
}

/// Encodes a JSON value into DAP wire format.
fn dap_encode(msg: &Value) -> Vec<u8> {
    let body = msg.to_string();
    let body_bytes = body.as_bytes();
    let mut out = Vec::new();
    out.extend(format!("Content-Length: {}\r\n\r\n", body_bytes.len()).as_bytes());
    out.extend(body_bytes);
    out
}

/// Reads a single DAP-framed JSON message from a Unix stream.
async fn dap_read(stream: &mut UnixStream) -> Result<Value, String> {
    let mut header_buf = Vec::with_capacity(256);
    let mut single = [0u8; 1];
    loop {
        let n = stream
            .read(&mut single)
            .await
            .map_err(|e| format!("read error: {e}"))?;
        if n == 0 {
            return Err("EOF while reading header".to_string());
        }
        header_buf.push(single[0]);
        if header_buf.len() >= 4 && header_buf.ends_with(b"\r\n\r\n") {
            break;
        }
        if header_buf.len() > 8192 {
            return Err("header too large".to_string());
        }
    }

    let header_str = String::from_utf8_lossy(&header_buf);
    let prefix = "Content-Length: ";
    let line = header_str
        .lines()
        .find(|l| l.starts_with(prefix))
        .ok_or("missing Content-Length")?;
    let content_length: usize = line[prefix.len()..]
        .trim()
        .parse()
        .map_err(|e| format!("bad Content-Length: {e}"))?;

    let mut body_buf = vec![0u8; content_length];
    stream
        .read_exact(&mut body_buf)
        .await
        .map_err(|e| format!("body read error: {e}"))?;

    serde_json::from_slice(&body_buf).map_err(|e| format!("json parse error: {e}"))
}

/// Waits for a Unix socket file to appear on disk.
async fn wait_for_socket(path: &Path, deadline: Duration) -> Result<(), String> {
    let start = tokio::time::Instant::now();
    while !path.exists() {
        if start.elapsed() > deadline {
            return Err(format!(
                "socket {} did not appear within {deadline:?}",
                path.display()
            ));
        }
        sleep(Duration::from_millis(50)).await;
    }
    Ok(())
}

/// Returns the `codetracer/` directory inside a test dir.
fn daemon_paths_in(test_dir: &Path) -> PathBuf {
    test_dir.join("codetracer")
}

/// Creates a test trace directory with metadata files.
fn create_test_trace_dir(parent: &Path, name: &str, program: &str) -> PathBuf {
    let trace_dir = parent.join(name);
    std::fs::create_dir_all(trace_dir.join("files")).expect("create trace dir");

    let metadata = json!({
        "workdir": "/tmp/test-workdir",
        "program": program,
        "args": []
    });
    std::fs::write(
        trace_dir.join("trace_metadata.json"),
        serde_json::to_string_pretty(&metadata).unwrap(),
    )
    .expect("write trace_metadata.json");

    let paths = json!(["src/main.rs", "src/lib.rs"]);
    std::fs::write(
        trace_dir.join("trace_paths.json"),
        serde_json::to_string(&paths).unwrap(),
    )
    .expect("write trace_paths.json");

    let events = json!([
        {"Path": "src/main.rs"},
        {"Function": {"name": "main", "path_id": 0, "line": 1}},
        {"Call": {"function_id": 0, "args": []}},
        {"Step": {"path_id": 0, "line": 1}},
        {"Step": {"path_id": 0, "line": 2}},
        {"Step": {"path_id": 0, "line": 3}},
    ]);
    std::fs::write(
        trace_dir.join("trace.json"),
        serde_json::to_string_pretty(&events).unwrap(),
    )
    .expect("write trace.json");

    trace_dir
}

/// Starts a daemon with MockDapBackend and returns (child, socket_path).
async fn start_daemon_with_mock_dap(
    test_dir: &Path,
    log_path: &Path,
    extra_env: &[(&str, &str)],
) -> (tokio::process::Child, PathBuf) {
    let ct_dir = daemon_paths_in(test_dir);
    std::fs::create_dir_all(&ct_dir).expect("create ct dir");

    let socket_path = ct_dir.join("daemon.sock");
    let pid_path = ct_dir.join("daemon.pid");
    let _ = std::fs::remove_file(&socket_path);
    let _ = std::fs::remove_file(&pid_path);

    log_line(
        log_path,
        &format!("starting daemon, TMPDIR={}", test_dir.display()),
    );

    let bin = binary_path();
    let bin_str = bin.to_string_lossy().to_string();

    let mut cmd = Command::new(&bin);
    cmd.arg("daemon")
        .arg("start")
        .env("TMPDIR", test_dir)
        .env("CODETRACER_DB_BACKEND_CMD", &bin_str)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    for (key, value) in extra_env {
        cmd.env(key, value);
    }

    let child = cmd.spawn().expect("cannot spawn daemon");

    wait_for_socket(&socket_path, Duration::from_secs(10))
        .await
        .expect("daemon socket did not appear in time");

    log_line(log_path, "daemon socket appeared");
    (child, socket_path)
}

/// Sends `ct/daemon-shutdown` and waits for the daemon to exit.
async fn shutdown_daemon(stream: &mut UnixStream, child: &mut tokio::process::Child) {
    let req = json!({"type": "request", "command": "ct/daemon-shutdown", "seq": 9999});
    let _ = stream.write_all(&dap_encode(&req)).await;
    let _ = timeout(Duration::from_secs(5), child.wait()).await;
    let _ = child.kill().await;
}

/// Opens a trace via the daemon DAP socket.
async fn open_trace(
    client: &mut UnixStream,
    seq: i64,
    trace_path: &Path,
    log_path: &Path,
) -> Result<Value, String> {
    let req = json!({
        "type": "request",
        "command": "ct/open-trace",
        "seq": seq,
        "arguments": {
            "tracePath": trace_path.to_string_lossy(),
        }
    });
    client
        .write_all(&dap_encode(&req))
        .await
        .map_err(|e| format!("write ct/open-trace: {e}"))?;

    let resp = timeout(Duration::from_secs(30), dap_read(client))
        .await
        .map_err(|_| "timeout waiting for ct/open-trace response".to_string())?
        .map_err(|e| format!("read ct/open-trace response: {e}"))?;

    log_line(log_path, &format!("ct/open-trace response: {resp}"));
    Ok(resp)
}

/// Reports test result.
fn report(test_name: &str, log_path: &Path, success: bool) {
    if success {
        println!("{test_name}: PASS");
    } else {
        let size = std::fs::metadata(log_path).map(|m| m.len()).unwrap_or(0);
        eprintln!(
            "{test_name}: FAIL  (log: {} [{size} bytes])",
            log_path.display()
        );
    }
}

// ---------------------------------------------------------------------------
// MCP server process helpers
// ---------------------------------------------------------------------------

/// Spawns the MCP server process with stdin/stdout piped.
///
/// The `daemon_socket_path` is passed via CODETRACER_DAEMON_SOCK so the
/// MCP server connects to the test daemon instead of auto-starting one.
fn spawn_mcp_server(
    test_dir: &Path,
    daemon_socket_path: &Path,
) -> tokio::process::Child {
    let bin = binary_path();
    Command::new(&bin)
        .arg("trace")
        .arg("mcp")
        .env("TMPDIR", test_dir)
        .env(
            "CODETRACER_DAEMON_SOCK",
            daemon_socket_path.to_string_lossy().to_string(),
        )
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("cannot spawn MCP server")
}

/// Sends a JSON-RPC message to the MCP server's stdin.
async fn mcp_send(
    stdin: &mut tokio::process::ChildStdin,
    msg: &Value,
) -> Result<(), String> {
    let line = serde_json::to_string(msg).map_err(|e| format!("serialize: {e}"))?;
    stdin
        .write_all(line.as_bytes())
        .await
        .map_err(|e| format!("stdin write: {e}"))?;
    stdin
        .write_all(b"\n")
        .await
        .map_err(|e| format!("stdin write newline: {e}"))?;
    stdin
        .flush()
        .await
        .map_err(|e| format!("stdin flush: {e}"))?;
    Ok(())
}

/// Reads a single JSON-RPC response line from the MCP server's stdout.
///
/// Returns the parsed JSON value.  Times out after the given duration.
async fn mcp_read(
    reader: &mut BufReader<tokio::process::ChildStdout>,
    deadline: Duration,
) -> Result<Value, String> {
    let mut line = String::new();
    let result = timeout(deadline, reader.read_line(&mut line))
        .await
        .map_err(|_| "timeout reading MCP response".to_string())?
        .map_err(|e| format!("stdout read: {e}"))?;

    if result == 0 {
        return Err("EOF from MCP server stdout".to_string());
    }

    serde_json::from_str(line.trim())
        .map_err(|e| format!("json parse error: {e} (raw: {line})"))
}

/// Performs the MCP initialize handshake (initialize request + notifications/initialized).
async fn mcp_initialize(
    stdin: &mut tokio::process::ChildStdin,
    reader: &mut BufReader<tokio::process::ChildStdout>,
) -> Result<Value, String> {
    let init_req = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "clientInfo": {"name": "test", "version": "1.0"}
        }
    });
    mcp_send(stdin, &init_req).await?;
    let resp = mcp_read(reader, Duration::from_secs(5)).await?;

    // Send notifications/initialized.
    let initialized = json!({
        "jsonrpc": "2.0",
        "method": "notifications/initialized"
    });
    mcp_send(stdin, &initialized).await?;

    Ok(resp)
}

// ---------------------------------------------------------------------------
// V-M10-INIT: mcp_initialize_handshake
// ---------------------------------------------------------------------------

/// Start MCP server.  Send initialize request.  Verify response contains
/// server info (name, version) and capabilities (tools, prompts).
#[tokio::test]
async fn mcp_initialize_handshake() {
    let (test_dir, log_path) = setup_test_dir("mcp_initialize_handshake");
    let mut success = false;

    let result: Result<(), String> = async {
        // We don't need a daemon for the initialize handshake — it doesn't
        // connect to the daemon until a tool is called.
        let mut mcp = {
            let bin = binary_path();
            Command::new(&bin)
                .arg("trace")
                .arg("mcp")
                .env("TMPDIR", &test_dir)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .expect("cannot spawn MCP server")
        };

        let mut stdin = mcp.stdin.take().expect("no stdin");
        let stdout = mcp.stdout.take().expect("no stdout");
        let mut reader = BufReader::new(stdout);

        let resp = mcp_initialize(&mut stdin, &mut reader).await?;
        log_line(&log_path, &format!("initialize response: {resp}"));

        // Verify structure.
        assert_eq!(resp["jsonrpc"], "2.0");
        assert_eq!(resp["id"], 1);

        let result = &resp["result"];
        assert_eq!(result["protocolVersion"], "2024-11-05");
        assert_eq!(result["serverInfo"]["name"], "codetracer-trace-query");
        assert!(
            result["serverInfo"]["version"].is_string(),
            "version should be a string"
        );
        assert!(result["capabilities"]["tools"].is_object());
        assert!(result["capabilities"]["prompts"].is_object());

        // Close stdin to let the server exit.
        drop(stdin);
        let _ = timeout(Duration::from_secs(2), mcp.wait()).await;
        let _ = mcp.kill().await;

        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("mcp_initialize_handshake", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

// ---------------------------------------------------------------------------
// V-M10-TOOLS-LIST: mcp_tools_list
// ---------------------------------------------------------------------------

/// Send tools/list request.  Verify response lists exec_script, trace_info,
/// list_source_files, read_source_file tools with correct schemas.
#[tokio::test]
async fn mcp_tools_list() {
    let (test_dir, log_path) = setup_test_dir("mcp_tools_list");
    let mut success = false;

    let result: Result<(), String> = async {
        let mut mcp = {
            let bin = binary_path();
            Command::new(&bin)
                .arg("trace")
                .arg("mcp")
                .env("TMPDIR", &test_dir)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .expect("cannot spawn MCP server")
        };

        let mut stdin = mcp.stdin.take().expect("no stdin");
        let stdout = mcp.stdout.take().expect("no stdout");
        let mut reader = BufReader::new(stdout);

        // Initialize first.
        mcp_initialize(&mut stdin, &mut reader).await?;

        // Send tools/list.
        let req = json!({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list"
        });
        mcp_send(&mut stdin, &req).await?;
        let resp = mcp_read(&mut reader, Duration::from_secs(5)).await?;
        log_line(&log_path, &format!("tools/list response: {resp}"));

        assert_eq!(resp["jsonrpc"], "2.0");
        assert_eq!(resp["id"], 2);

        let tools = resp["result"]["tools"]
            .as_array()
            .expect("tools should be an array");
        assert_eq!(tools.len(), 4, "expected 4 tools");

        let names: Vec<&str> = tools
            .iter()
            .map(|t| t["name"].as_str().unwrap())
            .collect();
        assert!(names.contains(&"exec_script"), "missing exec_script");
        assert!(names.contains(&"trace_info"), "missing trace_info");
        assert!(names.contains(&"list_source_files"), "missing list_source_files");
        assert!(names.contains(&"read_source_file"), "missing read_source_file");

        // Verify each tool has an inputSchema with required fields.
        for tool in tools {
            let schema = tool
                .get("inputSchema")
                .expect("tool should have inputSchema");
            assert_eq!(schema["type"], "object", "inputSchema should be object type");
            assert!(
                schema.get("properties").is_some(),
                "inputSchema should have properties"
            );
            assert!(
                schema.get("required").is_some(),
                "inputSchema should have required"
            );
        }

        // Verify exec_script has trace_path, script, timeout_seconds properties.
        let exec_tool = tools.iter().find(|t| t["name"] == "exec_script").unwrap();
        let props = &exec_tool["inputSchema"]["properties"];
        assert!(props.get("trace_path").is_some(), "exec_script missing trace_path");
        assert!(props.get("script").is_some(), "exec_script missing script");
        assert!(
            props.get("timeout_seconds").is_some(),
            "exec_script missing timeout_seconds"
        );

        drop(stdin);
        let _ = timeout(Duration::from_secs(2), mcp.wait()).await;
        let _ = mcp.kill().await;

        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("mcp_tools_list", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

// ---------------------------------------------------------------------------
// V-M10-EXEC: mcp_exec_script_returns_output
// ---------------------------------------------------------------------------

/// Send tools/call with exec_script, trace path, and script "print('hello')".
/// Verify response content contains "hello".
#[tokio::test]
async fn mcp_exec_script_returns_output() {
    let (test_dir, log_path) = setup_test_dir("mcp_exec_script_output");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-exec", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        // Pre-open the trace on the daemon so exec_script can find it.
        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;
        let open_resp = open_trace(&mut client, 100, &trace_dir, &log_path).await?;
        assert_eq!(
            open_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "open should succeed: {open_resp}"
        );

        // Spawn MCP server.
        let mut mcp = spawn_mcp_server(&test_dir, &socket_path);
        let mut stdin = mcp.stdin.take().expect("no stdin");
        let stdout = mcp.stdout.take().expect("no stdout");
        let mut reader = BufReader::new(stdout);

        mcp_initialize(&mut stdin, &mut reader).await?;

        // Send exec_script tool call.
        let req = json!({
            "jsonrpc": "2.0",
            "id": 10,
            "method": "tools/call",
            "params": {
                "name": "exec_script",
                "arguments": {
                    "trace_path": trace_dir.to_string_lossy(),
                    "script": "print('hello')"
                }
            }
        });
        mcp_send(&mut stdin, &req).await?;
        let resp = mcp_read(&mut reader, Duration::from_secs(60)).await?;
        log_line(&log_path, &format!("exec_script response: {resp}"));

        assert_eq!(resp["jsonrpc"], "2.0");
        assert_eq!(resp["id"], 10);

        let content = &resp["result"]["content"];
        let text = content[0]["text"].as_str().expect("should have text");
        log_line(&log_path, &format!("exec_script text: {text}"));
        assert!(
            text.contains("hello"),
            "exec_script output should contain 'hello', got: {text}"
        );

        // Should NOT have isError.
        assert!(
            resp["result"].get("isError").is_none()
                || resp["result"]["isError"] == Value::Bool(false),
            "exec_script should not have isError"
        );

        drop(stdin);
        let _ = timeout(Duration::from_secs(2), mcp.wait()).await;
        let _ = mcp.kill().await;
        shutdown_daemon(&mut client, &mut daemon).await;

        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("mcp_exec_script_returns_output", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

// ---------------------------------------------------------------------------
// V-M10-EXEC-ERR: mcp_exec_script_error
// ---------------------------------------------------------------------------

/// Send tools/call with exec_script and script "1/0".
/// Verify response has isError: true and content includes "ZeroDivisionError".
#[tokio::test]
async fn mcp_exec_script_error() {
    let (test_dir, log_path) = setup_test_dir("mcp_exec_script_error");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-err", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;
        let open_resp = open_trace(&mut client, 100, &trace_dir, &log_path).await?;
        assert_eq!(
            open_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "open should succeed"
        );

        let mut mcp = spawn_mcp_server(&test_dir, &socket_path);
        let mut stdin = mcp.stdin.take().expect("no stdin");
        let stdout = mcp.stdout.take().expect("no stdout");
        let mut reader = BufReader::new(stdout);

        mcp_initialize(&mut stdin, &mut reader).await?;

        // Send exec_script with a script that raises ZeroDivisionError.
        let req = json!({
            "jsonrpc": "2.0",
            "id": 11,
            "method": "tools/call",
            "params": {
                "name": "exec_script",
                "arguments": {
                    "trace_path": trace_dir.to_string_lossy(),
                    "script": "1/0"
                }
            }
        });
        mcp_send(&mut stdin, &req).await?;
        let resp = mcp_read(&mut reader, Duration::from_secs(60)).await?;
        log_line(&log_path, &format!("exec_script error response: {resp}"));

        assert_eq!(resp["jsonrpc"], "2.0");
        assert_eq!(resp["id"], 11);

        // Should have isError: true.
        assert_eq!(
            resp["result"]["isError"],
            Value::Bool(true),
            "exec_script error should have isError: true"
        );

        let text = resp["result"]["content"][0]["text"]
            .as_str()
            .expect("should have text");
        log_line(&log_path, &format!("exec_script error text: {text}"));
        assert!(
            text.contains("ZeroDivisionError"),
            "error text should contain 'ZeroDivisionError', got: {text}"
        );

        drop(stdin);
        let _ = timeout(Duration::from_secs(2), mcp.wait()).await;
        let _ = mcp.kill().await;
        shutdown_daemon(&mut client, &mut daemon).await;

        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("mcp_exec_script_error", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

// ---------------------------------------------------------------------------
// V-M10-INFO: mcp_trace_info
// ---------------------------------------------------------------------------

/// Send tools/call with trace_info and a trace path.
/// Verify response contains language, event count, source files.
#[tokio::test]
async fn mcp_trace_info() {
    let (test_dir, log_path) = setup_test_dir("mcp_trace_info");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-info", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        let mut mcp = spawn_mcp_server(&test_dir, &socket_path);
        let mut stdin = mcp.stdin.take().expect("no stdin");
        let stdout = mcp.stdout.take().expect("no stdout");
        let mut reader = BufReader::new(stdout);

        mcp_initialize(&mut stdin, &mut reader).await?;

        // Send trace_info tool call.
        let req = json!({
            "jsonrpc": "2.0",
            "id": 20,
            "method": "tools/call",
            "params": {
                "name": "trace_info",
                "arguments": {
                    "trace_path": trace_dir.to_string_lossy()
                }
            }
        });
        mcp_send(&mut stdin, &req).await?;
        let resp = mcp_read(&mut reader, Duration::from_secs(30)).await?;
        log_line(&log_path, &format!("trace_info response: {resp}"));

        assert_eq!(resp["jsonrpc"], "2.0");
        assert_eq!(resp["id"], 20);

        // Should not have isError.
        assert!(
            resp["result"].get("isError").is_none()
                || resp["result"]["isError"] == Value::Bool(false),
            "trace_info should not have isError"
        );

        let text = resp["result"]["content"][0]["text"]
            .as_str()
            .expect("should have text");
        log_line(&log_path, &format!("trace_info text: {text}"));

        // Verify the text contains expected metadata fields.
        assert!(text.contains("Language"), "should contain language info");
        assert!(
            text.contains("nim") || text.contains("Nim"),
            "should contain 'nim' as language"
        );
        assert!(
            text.contains("Source files") || text.contains("source"),
            "should contain source files info"
        );

        drop(stdin);
        let _ = timeout(Duration::from_secs(2), mcp.wait()).await;
        let _ = mcp.kill().await;
        shutdown_daemon(&mut client, &mut daemon).await;

        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("mcp_trace_info", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

// ---------------------------------------------------------------------------
// V-M10-SOURCE-LIST: mcp_list_source_files
// ---------------------------------------------------------------------------

/// Send tools/call with list_source_files.
/// Verify response contains a list of file paths.
#[tokio::test]
async fn mcp_list_source_files() {
    let (test_dir, log_path) = setup_test_dir("mcp_list_source_files");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-list", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        let mut mcp = spawn_mcp_server(&test_dir, &socket_path);
        let mut stdin = mcp.stdin.take().expect("no stdin");
        let stdout = mcp.stdout.take().expect("no stdout");
        let mut reader = BufReader::new(stdout);

        mcp_initialize(&mut stdin, &mut reader).await?;

        let req = json!({
            "jsonrpc": "2.0",
            "id": 30,
            "method": "tools/call",
            "params": {
                "name": "list_source_files",
                "arguments": {
                    "trace_path": trace_dir.to_string_lossy()
                }
            }
        });
        mcp_send(&mut stdin, &req).await?;
        let resp = mcp_read(&mut reader, Duration::from_secs(30)).await?;
        log_line(&log_path, &format!("list_source_files response: {resp}"));

        assert_eq!(resp["jsonrpc"], "2.0");
        assert_eq!(resp["id"], 30);

        let text = resp["result"]["content"][0]["text"]
            .as_str()
            .expect("should have text");
        log_line(&log_path, &format!("list_source_files text: {text}"));

        // The test trace has src/main.rs and src/lib.rs.
        assert!(
            text.contains("src/main.rs"),
            "should list src/main.rs, got: {text}"
        );
        assert!(
            text.contains("src/lib.rs"),
            "should list src/lib.rs, got: {text}"
        );

        drop(stdin);
        let _ = timeout(Duration::from_secs(2), mcp.wait()).await;
        let _ = mcp.kill().await;
        shutdown_daemon(&mut client, &mut daemon).await;

        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("mcp_list_source_files", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

// ---------------------------------------------------------------------------
// V-M10-SOURCE-READ: mcp_read_source_file
// ---------------------------------------------------------------------------

/// Send tools/call with read_source_file and a valid file path.
/// Verify response contains source code text.
#[tokio::test]
async fn mcp_read_source_file() {
    let (test_dir, log_path) = setup_test_dir("mcp_read_source_file");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-read", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        // Pre-open the trace.
        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;
        let open_resp = open_trace(&mut client, 100, &trace_dir, &log_path).await?;
        assert_eq!(
            open_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "open should succeed"
        );

        let mut mcp = spawn_mcp_server(&test_dir, &socket_path);
        let mut stdin = mcp.stdin.take().expect("no stdin");
        let stdout = mcp.stdout.take().expect("no stdout");
        let mut reader = BufReader::new(stdout);

        mcp_initialize(&mut stdin, &mut reader).await?;

        let req = json!({
            "jsonrpc": "2.0",
            "id": 40,
            "method": "tools/call",
            "params": {
                "name": "read_source_file",
                "arguments": {
                    "trace_path": trace_dir.to_string_lossy(),
                    "file_path": "main.nim"
                }
            }
        });
        mcp_send(&mut stdin, &req).await?;
        let resp = mcp_read(&mut reader, Duration::from_secs(30)).await?;
        log_line(&log_path, &format!("read_source_file response: {resp}"));

        assert_eq!(resp["jsonrpc"], "2.0");
        assert_eq!(resp["id"], 40);

        let text = resp["result"]["content"][0]["text"]
            .as_str()
            .expect("should have text");
        log_line(&log_path, &format!("read_source_file text: {text}"));

        // The mock-dap-backend returns content for "main" files containing
        // "proc main()" — verify we got some source code.
        assert!(
            !text.is_empty(),
            "source file content should not be empty"
        );
        assert!(
            text.contains("proc main") || text.contains("main"),
            "source file should contain main function, got: {text}"
        );

        drop(stdin);
        let _ = timeout(Duration::from_secs(2), mcp.wait()).await;
        let _ = mcp.kill().await;
        shutdown_daemon(&mut client, &mut daemon).await;

        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("mcp_read_source_file", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

// ---------------------------------------------------------------------------
// V-M10-PROMPTS-LIST: mcp_prompts_list
// ---------------------------------------------------------------------------

/// Send prompts/list.  Verify trace_query_api prompt is listed.
#[tokio::test]
async fn mcp_prompts_list() {
    let (test_dir, log_path) = setup_test_dir("mcp_prompts_list");
    let mut success = false;

    let result: Result<(), String> = async {
        let mut mcp = {
            let bin = binary_path();
            Command::new(&bin)
                .arg("trace")
                .arg("mcp")
                .env("TMPDIR", &test_dir)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .expect("cannot spawn MCP server")
        };

        let mut stdin = mcp.stdin.take().expect("no stdin");
        let stdout = mcp.stdout.take().expect("no stdout");
        let mut reader = BufReader::new(stdout);

        mcp_initialize(&mut stdin, &mut reader).await?;

        let req = json!({
            "jsonrpc": "2.0",
            "id": 50,
            "method": "prompts/list"
        });
        mcp_send(&mut stdin, &req).await?;
        let resp = mcp_read(&mut reader, Duration::from_secs(5)).await?;
        log_line(&log_path, &format!("prompts/list response: {resp}"));

        assert_eq!(resp["jsonrpc"], "2.0");
        assert_eq!(resp["id"], 50);

        let prompts = resp["result"]["prompts"]
            .as_array()
            .expect("prompts should be an array");
        assert!(
            prompts
                .iter()
                .any(|p| p["name"].as_str() == Some("trace_query_api")),
            "should contain trace_query_api prompt"
        );

        drop(stdin);
        let _ = timeout(Duration::from_secs(2), mcp.wait()).await;
        let _ = mcp.kill().await;

        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("mcp_prompts_list", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

// ---------------------------------------------------------------------------
// V-M10-PROMPT-GET: mcp_prompt_returns_api_docs
// ---------------------------------------------------------------------------

/// Send prompts/get for trace_query_api.  Verify response contains the
/// Python API reference text (data types, Trace class methods).
#[tokio::test]
async fn mcp_prompt_returns_api_docs() {
    let (test_dir, log_path) = setup_test_dir("mcp_prompt_api_docs");
    let mut success = false;

    let result: Result<(), String> = async {
        let mut mcp = {
            let bin = binary_path();
            Command::new(&bin)
                .arg("trace")
                .arg("mcp")
                .env("TMPDIR", &test_dir)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .expect("cannot spawn MCP server")
        };

        let mut stdin = mcp.stdin.take().expect("no stdin");
        let stdout = mcp.stdout.take().expect("no stdout");
        let mut reader = BufReader::new(stdout);

        mcp_initialize(&mut stdin, &mut reader).await?;

        let req = json!({
            "jsonrpc": "2.0",
            "id": 60,
            "method": "prompts/get",
            "params": {
                "name": "trace_query_api"
            }
        });
        mcp_send(&mut stdin, &req).await?;
        let resp = mcp_read(&mut reader, Duration::from_secs(5)).await?;
        log_line(&log_path, &format!("prompts/get response: {resp}"));

        assert_eq!(resp["jsonrpc"], "2.0");
        assert_eq!(resp["id"], 60);

        let messages = resp["result"]["messages"]
            .as_array()
            .expect("should have messages array");
        assert!(!messages.is_empty(), "should have at least one message");

        let text = messages[0]["content"]["text"]
            .as_str()
            .expect("should have text");

        // Verify it contains key API elements.
        assert!(text.contains("Trace Query API"), "should contain API title");
        assert!(text.contains("Location"), "should contain Location type");
        assert!(text.contains("Variable"), "should contain Variable type");
        assert!(text.contains("Frame"), "should contain Frame type");
        assert!(text.contains("trace.step_over"), "should contain step_over method");
        assert!(text.contains("trace.locals"), "should contain locals method");
        assert!(text.contains("trace.evaluate"), "should contain evaluate method");
        assert!(text.contains("trace.stack_trace"), "should contain stack_trace");

        drop(stdin);
        let _ = timeout(Duration::from_secs(2), mcp.wait()).await;
        let _ = mcp.kill().await;

        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("mcp_prompt_returns_api_docs", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

// ---------------------------------------------------------------------------
// V-M10-STDOUT: mcp_no_stdout_corruption
// ---------------------------------------------------------------------------

/// Run MCP server with multiple requests.  Verify all JSON-RPC messages
/// are well-formed.  Verify no non-JSON output appears on stdout.
#[tokio::test]
async fn mcp_no_stdout_corruption() {
    let (test_dir, log_path) = setup_test_dir("mcp_no_stdout_corruption");
    let mut success = false;

    let result: Result<(), String> = async {
        let mut mcp = {
            let bin = binary_path();
            Command::new(&bin)
                .arg("trace")
                .arg("mcp")
                .env("TMPDIR", &test_dir)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .expect("cannot spawn MCP server")
        };

        let mut stdin = mcp.stdin.take().expect("no stdin");
        let stdout = mcp.stdout.take().expect("no stdout");
        let mut reader = BufReader::new(stdout);

        // Send multiple requests rapidly.
        let init_resp = mcp_initialize(&mut stdin, &mut reader).await?;
        assert_eq!(init_resp["jsonrpc"], "2.0", "init response malformed");

        // tools/list
        mcp_send(
            &mut stdin,
            &json!({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}),
        )
        .await?;
        let tools_resp = mcp_read(&mut reader, Duration::from_secs(5)).await?;
        assert_eq!(tools_resp["jsonrpc"], "2.0", "tools/list response malformed");

        // prompts/list
        mcp_send(
            &mut stdin,
            &json!({"jsonrpc": "2.0", "id": 3, "method": "prompts/list"}),
        )
        .await?;
        let prompts_resp = mcp_read(&mut reader, Duration::from_secs(5)).await?;
        assert_eq!(
            prompts_resp["jsonrpc"], "2.0",
            "prompts/list response malformed"
        );

        // prompts/get
        mcp_send(
            &mut stdin,
            &json!({
                "jsonrpc": "2.0", "id": 4,
                "method": "prompts/get",
                "params": {"name": "trace_query_api"}
            }),
        )
        .await?;
        let prompt_resp = mcp_read(&mut reader, Duration::from_secs(5)).await?;
        assert_eq!(
            prompt_resp["jsonrpc"], "2.0",
            "prompts/get response malformed"
        );

        // Unknown method (should return error, not corrupt stdout).
        mcp_send(
            &mut stdin,
            &json!({"jsonrpc": "2.0", "id": 5, "method": "nonexistent/method"}),
        )
        .await?;
        let err_resp = mcp_read(&mut reader, Duration::from_secs(5)).await?;
        assert_eq!(err_resp["jsonrpc"], "2.0", "error response malformed");
        assert!(
            err_resp.get("error").is_some(),
            "unknown method should return error"
        );

        // Close stdin and collect any remaining stdout.
        drop(stdin);

        // Read any remaining output — it should all be valid JSON or empty.
        let mut remaining = String::new();
        let read_result = timeout(
            Duration::from_secs(3),
            reader.read_to_string(&mut remaining),
        )
        .await;

        // If there is remaining output, verify each line is valid JSON.
        if let Ok(Ok(_)) = read_result {
            for line in remaining.lines() {
                let trimmed = line.trim();
                if trimmed.is_empty() {
                    continue;
                }
                assert!(
                    serde_json::from_str::<Value>(trimmed).is_ok(),
                    "non-JSON output on stdout: {trimmed}"
                );
            }
        }

        log_line(&log_path, "all stdout output is valid JSON");

        let _ = timeout(Duration::from_secs(2), mcp.wait()).await;
        let _ = mcp.kill().await;

        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("mcp_no_stdout_corruption", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}
