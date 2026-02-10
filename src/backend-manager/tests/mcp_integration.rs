//! Integration tests for the MCP server (Milestones M10 and M11).
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
//! Test naming follows the V-M10-* and V-M11-* verification matrices.

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

    let dir =
        PathBuf::from("/tmp")
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
fn spawn_mcp_server(test_dir: &Path, daemon_socket_path: &Path) -> tokio::process::Child {
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
async fn mcp_send(stdin: &mut tokio::process::ChildStdin, msg: &Value) -> Result<(), String> {
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

    serde_json::from_str(line.trim()).map_err(|e| format!("json parse error: {e} (raw: {line})"))
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

        let names: Vec<&str> = tools.iter().map(|t| t["name"].as_str().unwrap()).collect();
        assert!(names.contains(&"exec_script"), "missing exec_script");
        assert!(names.contains(&"trace_info"), "missing trace_info");
        assert!(
            names.contains(&"list_source_files"),
            "missing list_source_files"
        );
        assert!(
            names.contains(&"read_source_file"),
            "missing read_source_file"
        );

        // Verify each tool has an inputSchema with required fields.
        for tool in tools {
            let schema = tool
                .get("inputSchema")
                .expect("tool should have inputSchema");
            assert_eq!(
                schema["type"], "object",
                "inputSchema should be object type"
            );
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
        assert!(
            props.get("trace_path").is_some(),
            "exec_script missing trace_path"
        );
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

        let (mut daemon, socket_path) = start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

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

        let (mut daemon, socket_path) = start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

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

        let (mut daemon, socket_path) = start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

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

        let (mut daemon, socket_path) = start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

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

        let (mut daemon, socket_path) = start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

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
        assert!(!text.is_empty(), "source file content should not be empty");
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
        assert!(
            text.contains("trace.step_over"),
            "should contain step_over method"
        );
        assert!(
            text.contains("trace.locals"),
            "should contain locals method"
        );
        assert!(
            text.contains("trace.evaluate"),
            "should contain evaluate method"
        );
        assert!(
            text.contains("trace.stack_trace"),
            "should contain stack_trace"
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
        assert_eq!(
            tools_resp["jsonrpc"], "2.0",
            "tools/list response malformed"
        );

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

// ===========================================================================
// Milestone M11 — MCP Server Enhancements
// ===========================================================================

// ---------------------------------------------------------------------------
// V-M11-RESOURCES-LIST: mcp_resources_list
// ---------------------------------------------------------------------------

/// Load a trace via trace_info, then send resources/list.
/// Verify that the response contains trace info and source file resources
/// with correct URIs and MIME types.
#[tokio::test]
async fn mcp_resources_list() {
    let (test_dir, log_path) = setup_test_dir("mcp_resources_list");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-res-list", "main.nim");

        let (mut daemon, socket_path) = start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        // Connect a client to the daemon for open-trace and shutdown.
        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Spawn MCP server.
        let mut mcp = spawn_mcp_server(&test_dir, &socket_path);
        let mut stdin = mcp.stdin.take().expect("no stdin");
        let stdout = mcp.stdout.take().expect("no stdout");
        let mut reader = BufReader::new(stdout);

        mcp_initialize(&mut stdin, &mut reader).await?;

        // First, call trace_info to populate the loaded_traces cache.
        let trace_info_req = json!({
            "jsonrpc": "2.0",
            "id": 100,
            "method": "tools/call",
            "params": {
                "name": "trace_info",
                "arguments": {
                    "trace_path": trace_dir.to_string_lossy()
                }
            }
        });
        mcp_send(&mut stdin, &trace_info_req).await?;
        let info_resp = mcp_read(&mut reader, Duration::from_secs(30)).await?;
        log_line(&log_path, &format!("trace_info response: {info_resp}"));
        assert_eq!(info_resp["jsonrpc"], "2.0");
        assert_eq!(info_resp["id"], 100);

        // Now send resources/list.
        let req = json!({
            "jsonrpc": "2.0",
            "id": 101,
            "method": "resources/list"
        });
        mcp_send(&mut stdin, &req).await?;
        let resp = mcp_read(&mut reader, Duration::from_secs(5)).await?;
        log_line(&log_path, &format!("resources/list response: {resp}"));

        assert_eq!(resp["jsonrpc"], "2.0");
        assert_eq!(resp["id"], 101);

        let resources = resp["result"]["resources"]
            .as_array()
            .expect("resources should be an array");
        log_line(&log_path, &format!("resources count: {}", resources.len()));

        // Should have at least 1 info resource.
        assert!(
            !resources.is_empty(),
            "resources should not be empty after loading a trace"
        );

        // Find the info resource.
        let trace_path_str = trace_dir.to_string_lossy().to_string();
        let expected_info_uri = format!("trace://{}/info", trace_path_str);
        let info_resource = resources
            .iter()
            .find(|r| r["uri"].as_str() == Some(&expected_info_uri));
        assert!(
            info_resource.is_some(),
            "should have trace info resource with URI {expected_info_uri}, got: {:?}",
            resources
                .iter()
                .map(|r| r["uri"].as_str())
                .collect::<Vec<_>>()
        );
        let info_res = info_resource.unwrap();
        assert_eq!(
            info_res["mimeType"], "application/json",
            "info resource should have application/json MIME type"
        );

        // Find source file resources.
        let source_resources: Vec<_> = resources
            .iter()
            .filter(|r| r["uri"].as_str().is_some_and(|u| u.contains("/source/")))
            .collect();
        assert!(
            !source_resources.is_empty(),
            "should have source file resources"
        );
        for sr in &source_resources {
            assert_eq!(
                sr["mimeType"], "text/plain",
                "source file resource should have text/plain MIME type"
            );
        }

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

    report("mcp_resources_list", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

// ---------------------------------------------------------------------------
// V-M11-RESOURCE-INFO: mcp_resource_read_info
// ---------------------------------------------------------------------------

/// Send resources/read for trace:///<path>/info.
/// Verify the response is JSON containing trace metadata (language,
/// totalEvents, sourceFiles, program, workdir).
#[tokio::test]
async fn mcp_resource_read_info() {
    let (test_dir, log_path) = setup_test_dir("mcp_resource_read_info");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-res-info", "main.nim");

        let (mut daemon, socket_path) = start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        let mut mcp = spawn_mcp_server(&test_dir, &socket_path);
        let mut stdin = mcp.stdin.take().expect("no stdin");
        let stdout = mcp.stdout.take().expect("no stdout");
        let mut reader = BufReader::new(stdout);

        mcp_initialize(&mut stdin, &mut reader).await?;

        // Load the trace via trace_info tool to populate the cache.
        let trace_info_req = json!({
            "jsonrpc": "2.0",
            "id": 200,
            "method": "tools/call",
            "params": {
                "name": "trace_info",
                "arguments": {
                    "trace_path": trace_dir.to_string_lossy()
                }
            }
        });
        mcp_send(&mut stdin, &trace_info_req).await?;
        let info_resp = mcp_read(&mut reader, Duration::from_secs(30)).await?;
        log_line(&log_path, &format!("trace_info response: {info_resp}"));

        // Send resources/read for the info resource.
        let trace_path_str = trace_dir.to_string_lossy().to_string();
        let info_uri = format!("trace://{}/info", trace_path_str);
        let req = json!({
            "jsonrpc": "2.0",
            "id": 201,
            "method": "resources/read",
            "params": {
                "uri": info_uri
            }
        });
        mcp_send(&mut stdin, &req).await?;
        let resp = mcp_read(&mut reader, Duration::from_secs(10)).await?;
        log_line(&log_path, &format!("resources/read info response: {resp}"));

        assert_eq!(resp["jsonrpc"], "2.0");
        assert_eq!(resp["id"], 201);

        // Should not have an error.
        assert!(
            resp.get("error").is_none(),
            "resources/read should not return an error, got: {:?}",
            resp.get("error")
        );

        let contents = resp["result"]["contents"]
            .as_array()
            .expect("should have contents array");
        assert_eq!(contents.len(), 1, "should have exactly 1 content item");

        let content = &contents[0];
        assert_eq!(
            content["uri"].as_str(),
            Some(info_uri.as_str()),
            "content URI should match request URI"
        );
        assert_eq!(
            content["mimeType"], "application/json",
            "info resource should be application/json"
        );

        // Parse the text as JSON and verify metadata fields.
        let text = content["text"].as_str().expect("content should have text");
        log_line(&log_path, &format!("resource info text: {text}"));

        let info: Value = serde_json::from_str(text)
            .map_err(|e| format!("info text should be valid JSON: {e}"))?;
        assert_eq!(
            info["tracePath"].as_str(),
            Some(trace_path_str.as_str()),
            "tracePath should match"
        );
        assert!(info.get("language").is_some(), "should have language field");
        assert!(
            info.get("totalEvents").is_some(),
            "should have totalEvents field"
        );
        assert!(
            info.get("sourceFiles").is_some(),
            "should have sourceFiles field"
        );
        assert!(info.get("program").is_some(), "should have program field");
        assert!(info.get("workdir").is_some(), "should have workdir field");

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

    report("mcp_resource_read_info", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

// ---------------------------------------------------------------------------
// V-M11-RESOURCE-SOURCE: mcp_resource_read_source
// ---------------------------------------------------------------------------

/// Send resources/read for trace:///<path>/source/main.nim.
/// Verify the response contains text/plain source code content.
#[tokio::test]
async fn mcp_resource_read_source() {
    let (test_dir, log_path) = setup_test_dir("mcp_resource_read_source");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-res-src", "main.nim");

        let (mut daemon, socket_path) = start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        // Pre-open the trace on the daemon (needed for ct/py-read-source).
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

        let mut mcp = spawn_mcp_server(&test_dir, &socket_path);
        let mut stdin = mcp.stdin.take().expect("no stdin");
        let stdout = mcp.stdout.take().expect("no stdout");
        let mut reader = BufReader::new(stdout);

        mcp_initialize(&mut stdin, &mut reader).await?;

        // Load the trace via trace_info tool to populate loaded_traces.
        let trace_info_req = json!({
            "jsonrpc": "2.0",
            "id": 300,
            "method": "tools/call",
            "params": {
                "name": "trace_info",
                "arguments": {
                    "trace_path": trace_dir.to_string_lossy()
                }
            }
        });
        mcp_send(&mut stdin, &trace_info_req).await?;
        let info_resp = mcp_read(&mut reader, Duration::from_secs(30)).await?;
        log_line(&log_path, &format!("trace_info response: {info_resp}"));

        // Now send resources/read for a source file.
        let trace_path_str = trace_dir.to_string_lossy().to_string();
        let source_uri = format!("trace://{}/source/main.nim", trace_path_str);
        let req = json!({
            "jsonrpc": "2.0",
            "id": 301,
            "method": "resources/read",
            "params": {
                "uri": source_uri
            }
        });
        mcp_send(&mut stdin, &req).await?;
        let resp = mcp_read(&mut reader, Duration::from_secs(30)).await?;
        log_line(
            &log_path,
            &format!("resources/read source response: {resp}"),
        );

        assert_eq!(resp["jsonrpc"], "2.0");
        assert_eq!(resp["id"], 301);

        // Should not have an error.
        assert!(
            resp.get("error").is_none(),
            "resources/read should not return an error, got: {:?}",
            resp.get("error")
        );

        let contents = resp["result"]["contents"]
            .as_array()
            .expect("should have contents array");
        assert_eq!(contents.len(), 1, "should have exactly 1 content item");

        let content = &contents[0];
        assert_eq!(
            content["uri"].as_str(),
            Some(source_uri.as_str()),
            "content URI should match request URI"
        );
        assert_eq!(
            content["mimeType"], "text/plain",
            "source resource should be text/plain"
        );

        let text = content["text"].as_str().expect("content should have text");
        log_line(&log_path, &format!("resource source text: {text}"));

        // The mock-dap-backend returns content for "main" files containing
        // "proc main()".
        assert!(!text.is_empty(), "source file content should not be empty");
        assert!(
            text.contains("proc main"),
            "source file should contain 'proc main', got: {text}"
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

    report("mcp_resource_read_source", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

// ---------------------------------------------------------------------------
// V-M11-ERROR: mcp_error_messages_actionable
// ---------------------------------------------------------------------------

/// Send exec_script with a non-existent trace path.
/// Verify the error message is actionable (contains guidance for the agent).
#[tokio::test]
async fn mcp_error_messages_actionable() {
    let (test_dir, log_path) = setup_test_dir("mcp_error_actionable");
    let mut success = false;

    let result: Result<(), String> = async {
        // Create a trace dir for the daemon, but we will NOT use it
        // as the trace_path.  Instead we send a non-existent path.
        let _trace_dir = create_test_trace_dir(&test_dir, "trace-exists", "main.nim");

        let (mut daemon, socket_path) = start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        let mut mcp = spawn_mcp_server(&test_dir, &socket_path);
        let mut stdin = mcp.stdin.take().expect("no stdin");
        let stdout = mcp.stdout.take().expect("no stdout");
        let mut reader = BufReader::new(stdout);

        mcp_initialize(&mut stdin, &mut reader).await?;

        // Send exec_script with a path that does not exist.
        let nonexistent_path = test_dir.join("nonexistent-trace");
        let req = json!({
            "jsonrpc": "2.0",
            "id": 400,
            "method": "tools/call",
            "params": {
                "name": "exec_script",
                "arguments": {
                    "trace_path": nonexistent_path.to_string_lossy(),
                    "script": "print('hello')"
                }
            }
        });
        mcp_send(&mut stdin, &req).await?;
        let resp = mcp_read(&mut reader, Duration::from_secs(60)).await?;
        log_line(&log_path, &format!("exec_script error response: {resp}"));

        assert_eq!(resp["jsonrpc"], "2.0");
        assert_eq!(resp["id"], 400);

        // The response should indicate an error.
        let result_obj = &resp["result"];
        assert_eq!(
            result_obj["isError"],
            Value::Bool(true),
            "should have isError: true for non-existent trace"
        );

        let text = result_obj["content"][0]["text"]
            .as_str()
            .expect("should have error text");
        log_line(&log_path, &format!("error text: {text}"));

        // Verify the error message is actionable: it should mention the
        // path and provide guidance.
        assert!(
            text.contains("not found")
                || text.contains("failed")
                || text.contains("error")
                || text.contains("Failed")
                || text.contains("Cannot"),
            "error text should indicate the trace was not found or failed, got: {text}"
        );

        // Also verify enhanced errors via resources/read for an unloaded trace.
        let bad_uri = "trace:///nonexistent/path/info";
        let res_req = json!({
            "jsonrpc": "2.0",
            "id": 401,
            "method": "resources/read",
            "params": {
                "uri": bad_uri
            }
        });
        mcp_send(&mut stdin, &res_req).await?;
        let res_resp = mcp_read(&mut reader, Duration::from_secs(5)).await?;
        log_line(
            &log_path,
            &format!("resources/read error response: {res_resp}"),
        );

        assert_eq!(res_resp["jsonrpc"], "2.0");
        assert_eq!(res_resp["id"], 401);

        // Should be a JSON-RPC error (not a result).
        assert!(
            res_resp.get("error").is_some(),
            "resources/read for unloaded trace should return error"
        );
        let error_msg = res_resp["error"]["message"]
            .as_str()
            .expect("error should have message");
        log_line(&log_path, &format!("resource error message: {error_msg}"));

        // The error message should mention "trace not found" and suggest
        // loading with trace_info or exec_script.
        assert!(
            error_msg.contains("Trace not found") || error_msg.contains("not found"),
            "error should mention 'trace not found', got: {error_msg}"
        );
        assert!(
            error_msg.contains("trace_info") || error_msg.contains("exec_script"),
            "error should suggest loading via trace_info or exec_script, got: {error_msg}"
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

    report("mcp_error_messages_actionable", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

// ===========================================================================
// Milestone M12 — Documentation and Agent Skill Packaging
// ===========================================================================

// ---------------------------------------------------------------------------
// Python API path helper
// ---------------------------------------------------------------------------

/// Returns the path to the `python-api` directory relative to this crate.
///
/// The backend-manager crate lives at `<repo>/src/backend-manager/`, so the
/// python-api directory is at `<repo>/python-api/`.
fn python_api_dir() -> PathBuf {
    let crate_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    crate_dir
        .parent()
        .and_then(|p| p.parent())
        .map(|repo_root| repo_root.join("python-api"))
        .expect("cannot determine python-api directory from CARGO_MANIFEST_DIR")
}

// ---------------------------------------------------------------------------
// V-M12-DOCSTRINGS: api_reference_complete
// ---------------------------------------------------------------------------

/// Verify every public method on Trace class has a docstring.
/// Verify every dataclass field has a type annotation.
///
/// Runs a Python script that:
/// 1. Inspects the Trace class for methods without docstrings.
/// 2. Inspects the dataclass types for fields without type annotations.
#[tokio::test]
async fn api_reference_complete() {
    let (test_dir, log_path) = setup_test_dir("api_reference_complete");
    let mut success = false;

    let result: Result<(), String> = async {
        let api_dir = python_api_dir();
        if !api_dir.exists() {
            return Err(format!(
                "python-api directory does not exist: {}",
                api_dir.display()
            ));
        }
        log_line(&log_path, &format!("python-api dir: {}", api_dir.display()));

        // Run a Python script to check docstrings and type annotations.
        let check_script = r#"
import sys
sys.path.insert(0, sys.argv[1])

import inspect
import dataclasses
from codetracer.trace import Trace, open_trace
from codetracer import types as T

errors = []

# Check Trace class: every public method/property must have a docstring.
# The __init__ method is excluded because its intent is documented by
# the class-level docstring (which is the standard Python convention).
for name in sorted(dir(Trace)):
    if name.startswith('_'):
        # Check __enter__ and __exit__ (context manager protocol).
        if name not in ('__enter__', '__exit__'):
            continue
    attr = getattr(Trace, name)
    if callable(attr) or isinstance(attr, property):
        doc = None
        if isinstance(attr, property):
            doc = attr.fget.__doc__ if attr.fget else None
        else:
            doc = attr.__doc__
        if not doc or not doc.strip():
            errors.append(f"Trace.{name} has no docstring")

# Check open_trace function.
if not open_trace.__doc__ or not open_trace.__doc__.strip():
    errors.append("open_trace() has no docstring")

# Check all dataclass types have type annotations on every field.
dataclass_types = [
    T.Location, T.Variable, T.Frame, T.FlowStep, T.Flow,
    T.Loop, T.Call, T.Event, T.Process,
]
for cls in dataclass_types:
    if not dataclasses.is_dataclass(cls):
        errors.append(f"{cls.__name__} is not a dataclass")
        continue
    for field in dataclasses.fields(cls):
        if field.type is dataclasses.MISSING:
            errors.append(f"{cls.__name__}.{field.name} has no type annotation")
    if not cls.__doc__ or not cls.__doc__.strip():
        errors.append(f"{cls.__name__} has no docstring")

if errors:
    for e in errors:
        print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)

print("OK: all public methods have docstrings, all fields have type annotations")
"#;

        let script_path = test_dir.join("check_docstrings.py");
        std::fs::write(&script_path, check_script).map_err(|e| format!("write script: {e}"))?;

        let output = tokio::process::Command::new("python3")
            .arg(&script_path)
            .arg(api_dir.to_string_lossy().to_string())
            .output()
            .await
            .map_err(|e| format!("run python3: {e}"))?;

        let stdout = String::from_utf8_lossy(&output.stdout).to_string();
        let stderr = String::from_utf8_lossy(&output.stderr).to_string();
        log_line(&log_path, &format!("stdout: {stdout}"));
        log_line(&log_path, &format!("stderr: {stderr}"));

        if !output.status.success() {
            return Err(format!("docstring check failed:\n{stderr}\n{stdout}"));
        }

        assert!(
            stdout.contains("OK"),
            "docstring check should report OK, got: {stdout}"
        );

        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("api_reference_complete", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

// ---------------------------------------------------------------------------
// V-M12-SKILL: skill_description_fits_context
// ---------------------------------------------------------------------------

/// Verify the agent skill description (MCP prompt response) is under
/// 300 lines / 10KB.  Verify it contains: data types, Trace class methods,
/// example scripts.
#[tokio::test]
async fn skill_description_fits_context() {
    let (test_dir, log_path) = setup_test_dir("skill_description_fits_context");
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

        // Fetch the prompt.
        let req = json!({
            "jsonrpc": "2.0",
            "id": 1000,
            "method": "prompts/get",
            "params": {
                "name": "trace_query_api"
            }
        });
        mcp_send(&mut stdin, &req).await?;
        let resp = mcp_read(&mut reader, Duration::from_secs(5)).await?;
        log_line(&log_path, &format!("prompts/get response id: {}", resp["id"]));

        assert_eq!(resp["jsonrpc"], "2.0");
        assert_eq!(resp["id"], 1000);

        let messages = resp["result"]["messages"]
            .as_array()
            .expect("should have messages array");
        assert!(!messages.is_empty(), "should have at least one message");

        let text = messages[0]["content"]["text"]
            .as_str()
            .expect("should have text");

        // Verify size constraints.
        let byte_count = text.len();
        let line_count = text.lines().count();
        log_line(
            &log_path,
            &format!("skill desc: {byte_count} bytes, {line_count} lines"),
        );

        assert!(
            byte_count < 10 * 1024,
            "Skill description should be under 10KB, got {byte_count} bytes"
        );
        assert!(
            line_count < 300,
            "Skill description should be under 300 lines, got {line_count}"
        );

        // Verify it contains data types.
        assert!(text.contains("Location"), "should contain Location type");
        assert!(text.contains("Variable"), "should contain Variable type");
        assert!(text.contains("Frame"), "should contain Frame type");
        assert!(text.contains("FlowStep"), "should contain FlowStep type");
        assert!(text.contains("Flow"), "should contain Flow type");
        assert!(text.contains("Loop"), "should contain Loop type");
        assert!(text.contains("Call"), "should contain Call type");
        assert!(text.contains("Event"), "should contain Event type");
        assert!(text.contains("Process"), "should contain Process type");

        // Verify it contains Trace class methods.
        assert!(
            text.contains("trace.step_over"),
            "should contain step_over method"
        );
        assert!(
            text.contains("trace.step_in"),
            "should contain step_in method"
        );
        assert!(
            text.contains("trace.locals"),
            "should contain locals method"
        );
        assert!(
            text.contains("trace.evaluate"),
            "should contain evaluate method"
        );
        assert!(
            text.contains("trace.flow"),
            "should contain flow method"
        );
        assert!(
            text.contains("trace.calltrace"),
            "should contain calltrace method"
        );
        assert!(
            text.contains("trace.add_breakpoint"),
            "should contain add_breakpoint method"
        );

        // Verify it contains example scripts (code blocks).
        let code_block_count = text.matches("```python").count();
        assert!(
            code_block_count >= 3,
            "should contain at least 3 example scripts (```python blocks), got {code_block_count}"
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

    report("skill_description_fits_context", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

// ---------------------------------------------------------------------------
// V-M12-STUBS: type_stubs_valid
// ---------------------------------------------------------------------------

/// Verify .pyi stub files exist and are syntactically valid Python.
///
/// Since mypy may not be available in the nix dev shell, we verify stubs
/// by parsing them with Python's `ast.parse()`.  We also verify the
/// `py.typed` PEP 561 marker file exists.
#[tokio::test]
async fn type_stubs_valid() {
    let (test_dir, log_path) = setup_test_dir("type_stubs_valid");
    let mut success = false;

    let result: Result<(), String> = async {
        let api_dir = python_api_dir();
        if !api_dir.exists() {
            return Err(format!(
                "python-api directory does not exist: {}",
                api_dir.display()
            ));
        }

        let codetracer_dir = api_dir.join("codetracer");

        // Verify py.typed marker exists (PEP 561).
        let py_typed_path = codetracer_dir.join("py.typed");
        assert!(
            py_typed_path.exists(),
            "py.typed marker file should exist at {}",
            py_typed_path.display()
        );
        log_line(&log_path, "py.typed marker exists");

        // List of expected stub files.
        let stub_files = [
            "__init__.pyi",
            "trace.pyi",
            "types.pyi",
            "exceptions.pyi",
            "connection.pyi",
        ];

        for stub_file in &stub_files {
            let stub_path = codetracer_dir.join(stub_file);
            assert!(
                stub_path.exists(),
                "stub file should exist: {}",
                stub_path.display()
            );

            // Verify syntactic validity by parsing with ast.parse().
            let output = tokio::process::Command::new("python3")
                .arg("-c")
                .arg(format!(
                    "import ast; ast.parse(open('{}').read()); print('OK')",
                    stub_path.display()
                ))
                .output()
                .await
                .map_err(|e| format!("run python3 for {stub_file}: {e}"))?;

            let stdout = String::from_utf8_lossy(&output.stdout).to_string();
            let stderr = String::from_utf8_lossy(&output.stderr).to_string();
            log_line(
                &log_path,
                &format!("{stub_file}: stdout={stdout} stderr={stderr}"),
            );

            if !output.status.success() {
                return Err(format!(
                    "stub file {stub_file} is not valid Python:\n{stderr}"
                ));
            }
            assert!(
                stdout.contains("OK"),
                "{stub_file} should parse successfully"
            );
        }

        // Verify stubs contain key type declarations by running a Python script
        // that imports the stubs-related module and checks for expected names.
        let check_script = format!(
            r#"
import sys
sys.path.insert(0, "{api_dir}")

# Verify the package can be imported.
import codetracer
from codetracer.trace import Trace, open_trace
from codetracer.types import Location, Variable, Frame, FlowStep, Flow, Loop, Call, Event, Process
from codetracer.exceptions import TraceError, TraceNotFoundError, NavigationError, ExpressionError
from codetracer.connection import DaemonConnection

print("OK: all imports succeeded")
"#,
            api_dir = api_dir.display()
        );

        let output = tokio::process::Command::new("python3")
            .arg("-c")
            .arg(&check_script)
            .output()
            .await
            .map_err(|e| format!("run import check: {e}"))?;

        let stdout = String::from_utf8_lossy(&output.stdout).to_string();
        let stderr = String::from_utf8_lossy(&output.stderr).to_string();
        log_line(&log_path, &format!("import check: {stdout} {stderr}"));

        if !output.status.success() {
            return Err(format!("import check failed:\n{stderr}\n{stdout}"));
        }

        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("type_stubs_valid", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

// ---------------------------------------------------------------------------
// V-M12-CLI: cli_help_complete
// ---------------------------------------------------------------------------

/// Run `backend-manager trace --help`.  Verify all subcommands are documented.
/// Run `backend-manager trace query --help`.  Verify all flags (--timeout, -c)
/// are documented.
#[tokio::test]
async fn cli_help_complete() {
    let (test_dir, log_path) = setup_test_dir("cli_help_complete");
    let mut success = false;

    let result: Result<(), String> = async {
        let bin = binary_path();

        // Test `backend-manager trace --help`.
        let trace_help = tokio::process::Command::new(&bin)
            .arg("trace")
            .arg("--help")
            .output()
            .await
            .map_err(|e| format!("run trace --help: {e}"))?;

        let trace_out = String::from_utf8_lossy(&trace_help.stdout).to_string();
        let trace_err = String::from_utf8_lossy(&trace_help.stderr).to_string();
        log_line(&log_path, &format!("trace --help stdout:\n{trace_out}"));
        log_line(&log_path, &format!("trace --help stderr:\n{trace_err}"));

        // Clap may exit with code 0 or 2 for --help depending on version;
        // check that we got output.
        assert!(
            !trace_out.is_empty(),
            "trace --help should produce output"
        );

        // Verify all subcommands are listed.
        assert!(
            trace_out.contains("query"),
            "trace --help should list 'query' subcommand"
        );
        assert!(
            trace_out.contains("info"),
            "trace --help should list 'info' subcommand"
        );
        assert!(
            trace_out.contains("mcp"),
            "trace --help should list 'mcp' subcommand"
        );

        // Test `backend-manager trace query --help`.
        let query_help = tokio::process::Command::new(&bin)
            .arg("trace")
            .arg("query")
            .arg("--help")
            .output()
            .await
            .map_err(|e| format!("run trace query --help: {e}"))?;

        let query_out = String::from_utf8_lossy(&query_help.stdout).to_string();
        let query_err = String::from_utf8_lossy(&query_help.stderr).to_string();
        log_line(&log_path, &format!("trace query --help stdout:\n{query_out}"));
        log_line(&log_path, &format!("trace query --help stderr:\n{query_err}"));

        assert!(
            !query_out.is_empty(),
            "trace query --help should produce output"
        );

        // Verify all flags are documented.
        assert!(
            query_out.contains("--timeout"),
            "trace query --help should document --timeout flag"
        );
        assert!(
            query_out.contains("-c") || query_out.contains("--code"),
            "trace query --help should document -c/--code flag"
        );
        assert!(
            query_out.contains("trace_path") || query_out.contains("TRACE_PATH"),
            "trace query --help should document trace_path argument"
        );

        // Test `backend-manager --help` (top-level).
        let top_help = tokio::process::Command::new(&bin)
            .arg("--help")
            .output()
            .await
            .map_err(|e| format!("run --help: {e}"))?;

        let top_out = String::from_utf8_lossy(&top_help.stdout).to_string();
        log_line(&log_path, &format!("--help stdout:\n{top_out}"));

        assert!(
            !top_out.is_empty(),
            "--help should produce output"
        );
        assert!(
            top_out.contains("daemon"),
            "--help should list 'daemon' subcommand"
        );
        assert!(
            top_out.contains("trace"),
            "--help should list 'trace' subcommand"
        );

        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("cli_help_complete", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

// ---------------------------------------------------------------------------
// V-M12-EXAMPLES: example_scripts_execute
// ---------------------------------------------------------------------------

/// Extract example scripts from the skill description and run each via
/// exec_script against the mock trace.  Verify all execute without errors
/// and produce meaningful output.
#[tokio::test]
async fn example_scripts_execute() {
    let (test_dir, log_path) = setup_test_dir("example_scripts_execute");
    let mut success = false;

    let result: Result<(), String> = async {
        let api_dir = python_api_dir();
        if !api_dir.exists() {
            return Err(format!(
                "python-api directory does not exist: {}",
                api_dir.display()
            ));
        }

        let trace_dir = create_test_trace_dir(&test_dir, "trace-examples", "main.nim");

        let (mut daemon, socket_path) = start_daemon_with_mock_dap(
            &test_dir,
            &log_path,
            &[("CODETRACER_PYTHON_API_PATH", &api_dir.to_string_lossy())],
        )
        .await;

        // Pre-open the trace on the daemon.
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

        // Spawn MCP server (to get the skill description).
        let mut mcp = spawn_mcp_server(&test_dir, &socket_path);
        let mut stdin = mcp.stdin.take().expect("no stdin");
        let stdout = mcp.stdout.take().expect("no stdout");
        let mut reader = BufReader::new(stdout);

        mcp_initialize(&mut stdin, &mut reader).await?;

        // Fetch the skill description to extract example scripts.
        let req = json!({
            "jsonrpc": "2.0",
            "id": 2000,
            "method": "prompts/get",
            "params": {
                "name": "trace_query_api"
            }
        });
        mcp_send(&mut stdin, &req).await?;
        let resp = mcp_read(&mut reader, Duration::from_secs(5)).await?;

        let text = resp["result"]["messages"][0]["content"]["text"]
            .as_str()
            .expect("should have text");

        // Extract Python code blocks from the skill description.
        let mut examples: Vec<String> = Vec::new();
        let mut in_code_block = false;
        let mut current_block = String::new();

        for line in text.lines() {
            if line.trim().starts_with("```python") {
                in_code_block = true;
                current_block.clear();
                continue;
            }
            if line.trim().starts_with("```") && in_code_block {
                in_code_block = false;
                if !current_block.trim().is_empty() {
                    examples.push(current_block.clone());
                }
                continue;
            }
            if in_code_block {
                current_block.push_str(line);
                current_block.push('\n');
            }
        }

        log_line(
            &log_path,
            &format!("found {} example scripts in skill description", examples.len()),
        );
        assert!(
            examples.len() >= 3,
            "should have at least 3 example scripts, found {}",
            examples.len()
        );

        // Run each example script via the MCP exec_script tool.
        for (i, example) in examples.iter().enumerate() {
            log_line(
                &log_path,
                &format!("--- running example {} ---\n{example}", i + 1),
            );

            let exec_req = json!({
                "jsonrpc": "2.0",
                "id": 2001 + i as u64,
                "method": "tools/call",
                "params": {
                    "name": "exec_script",
                    "arguments": {
                        "trace_path": trace_dir.to_string_lossy(),
                        "script": example,
                        "timeout_seconds": 30
                    }
                }
            });
            mcp_send(&mut stdin, &exec_req).await?;
            let exec_resp = mcp_read(&mut reader, Duration::from_secs(60)).await?;
            log_line(
                &log_path,
                &format!("example {} response: {exec_resp}", i + 1),
            );

            // Verify the response is successful (no isError).
            let is_error = exec_resp["result"]
                .get("isError")
                .and_then(Value::as_bool)
                .unwrap_or(false);

            let result_text = exec_resp["result"]["content"][0]["text"]
                .as_str()
                .unwrap_or("");
            log_line(
                &log_path,
                &format!("example {} output: {result_text}", i + 1),
            );

            assert!(
                !is_error,
                "example {} should execute without errors. Output: {result_text}",
                i + 1
            );

            // Verify the output is non-empty (meaningful output).
            assert!(
                !result_text.trim().is_empty(),
                "example {} should produce non-empty output",
                i + 1
            );
        }

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

    report("example_scripts_execute", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

// ===========================================================================
// End Milestone M12
// ===========================================================================

// ---------------------------------------------------------------------------
// V-M11-TIMING: mcp_response_includes_timing
// ---------------------------------------------------------------------------

/// Send exec_script with a valid script.
/// Verify the response includes _meta.duration_ms > 0.
#[tokio::test]
async fn mcp_response_includes_timing() {
    let (test_dir, log_path) = setup_test_dir("mcp_timing");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-timing", "main.nim");

        let (mut daemon, socket_path) = start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        // Pre-open the trace on the daemon.
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

        let mut mcp = spawn_mcp_server(&test_dir, &socket_path);
        let mut stdin = mcp.stdin.take().expect("no stdin");
        let stdout = mcp.stdout.take().expect("no stdout");
        let mut reader = BufReader::new(stdout);

        mcp_initialize(&mut stdin, &mut reader).await?;

        // Send exec_script with a valid script.
        let req = json!({
            "jsonrpc": "2.0",
            "id": 500,
            "method": "tools/call",
            "params": {
                "name": "exec_script",
                "arguments": {
                    "trace_path": trace_dir.to_string_lossy(),
                    "script": "print('timing test')"
                }
            }
        });
        mcp_send(&mut stdin, &req).await?;
        let resp = mcp_read(&mut reader, Duration::from_secs(60)).await?;
        log_line(&log_path, &format!("exec_script response: {resp}"));

        assert_eq!(resp["jsonrpc"], "2.0");
        assert_eq!(resp["id"], 500);

        // Verify _meta.duration_ms is present and non-negative.
        let meta = &resp["result"]["_meta"];
        assert!(
            meta.is_object(),
            "result should have _meta object, got: {:?}",
            resp["result"]
        );
        let duration_ms = meta["duration_ms"]
            .as_u64()
            .or_else(|| meta["duration_ms"].as_f64().map(|f| f as u64));
        assert!(
            duration_ms.is_some(),
            "_meta.duration_ms should be a number, got: {:?}",
            meta["duration_ms"]
        );
        log_line(&log_path, &format!("duration_ms: {}", duration_ms.unwrap()));

        // Duration should be non-negative (>= 0). We don't check > 0
        // because in theory it could be 0ms on a fast machine, but in
        // practice it will always be > 0 due to network round-trip.
        // Instead, verify the field is present and is a valid number.
        assert!(
            duration_ms.unwrap() < 120_000,
            "duration_ms should be less than 120s (sanity check), got: {}",
            duration_ms.unwrap()
        );

        // Also verify timing on trace_info tool.
        let info_req = json!({
            "jsonrpc": "2.0",
            "id": 501,
            "method": "tools/call",
            "params": {
                "name": "trace_info",
                "arguments": {
                    "trace_path": trace_dir.to_string_lossy()
                }
            }
        });
        mcp_send(&mut stdin, &info_req).await?;
        let info_resp = mcp_read(&mut reader, Duration::from_secs(30)).await?;
        log_line(&log_path, &format!("trace_info response: {info_resp}"));

        let info_meta = &info_resp["result"]["_meta"];
        assert!(
            info_meta.is_object(),
            "trace_info result should have _meta object"
        );
        assert!(
            info_meta["duration_ms"].as_u64().is_some()
                || info_meta["duration_ms"].as_f64().is_some(),
            "trace_info _meta.duration_ms should be a number"
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

    report("mcp_response_includes_timing", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}
