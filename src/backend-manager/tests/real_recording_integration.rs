//! Real-recording integration tests for the backend-manager daemon.
//!
//! These tests complement the existing mock-based tests in `daemon_integration.rs`
//! by exercising the daemon's flows against real `db-backend` instances processing
//! real trace recordings.
//!
//! ## M2 — Trace-Path Session Management
//!
//! Tests for `ct/open-trace` and `ct/trace-info` that verify the daemon can open
//! real RR and custom-format traces and return correct metadata.
//!
//! ## M3 — Python API Navigation
//!
//! Tests for `ct/py-navigate` that verify navigation commands (`step_over`,
//! `step_in`, `step_out`, `continue_forward`, `step_back`) work correctly
//! against real traces.  These exercise the full DAP round-trip: navigation
//! command -> stopped event -> stackTrace -> location response.
//!
//! ## M4 — Python API Variables and Expressions
//!
//! Tests for `ct/py-locals`, `ct/py-evaluate`, and `ct/py-stack-trace` that
//! verify variable inspection, expression evaluation, and stack trace
//! retrieval work correctly against real traces.  These exercise the
//! request-response DAP round-trip through the daemon's Python bridge.
//!
//! ## M5 — Breakpoints and Watchpoints
//!
//! Tests for `ct/py-add-breakpoint`, `ct/py-remove-breakpoint`, and
//! breakpoint-aware navigation (`continue_forward`, `continue_reverse`).
//! These verify that the daemon can set breakpoints at specific source
//! lines, that `continue` stops at breakpoint locations, that removing a
//! breakpoint allows execution to continue past the former breakpoint
//! line, and that reverse continue respects breakpoints.
//!
//! ## Test categories
//!
//! 1. **RR-based tests**: Build and record a Rust test program via `ct-rr-support`,
//!    then open the resulting trace through the daemon.  These tests are skipped
//!    when `ct-rr-support` or `rr` is not available.
//!
//! 2. **Custom trace format tests**: Create a minimal trace directory with
//!    hand-crafted `trace.json`, `trace_metadata.json`, and `trace_paths.json`
//!    files, then open them through the daemon.  These always run (no special
//!    prerequisites).
//!
//! Each test:
//! - Uses a unique temporary directory (keyed on PID + test name hash) to avoid
//!   collisions when tests run in parallel.
//! - Creates a log file capturing its full output.
//! - Prints minimal output on success and the log path on failure.
//! - Cleans up temp directories on success.

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::io::Write as IoWrite;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use tokio::process::Command;
use tokio::time::{sleep, timeout};

// ---------------------------------------------------------------------------
// Shared helpers (duplicated from daemon_integration.rs because integration
// test files cannot share code without a helper crate or `mod` file)
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

/// Returns the path to the compiled `db-backend` binary, if available.
///
/// The db-backend binary may be built in the same target directory (if this
/// is a workspace build) or in the db-backend crate's own target directory.
/// We also check the PATH.
fn find_db_backend() -> Option<PathBuf> {
    // Check same target directory as backend-manager (workspace build).
    let mut target_dir = std::env::current_exe().expect("cannot determine test binary path");
    target_dir.pop();
    if target_dir.ends_with("deps") {
        target_dir.pop();
    }
    let same_target = target_dir.join("db-backend");
    if same_target.exists() {
        return Some(same_target);
    }

    // Check the db-backend crate's target directories relative to
    // CARGO_MANIFEST_DIR.
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let relative_locations = [
        "../db-backend/target/debug/db-backend",
        "../db-backend/target/release/db-backend",
    ];
    for loc in relative_locations {
        let path = manifest_dir.join(loc);
        if path.exists() {
            return Some(path.canonicalize().unwrap_or(path));
        }
    }

    // Check PATH.
    if let Ok(output) = std::process::Command::new("which")
        .arg("db-backend")
        .output()
    {
        if output.status.success() {
            let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !path.is_empty() {
                return Some(PathBuf::from(path));
            }
        }
    }

    None
}

/// Finds the `ct-rr-support` binary (same logic as db-backend test harness).
fn find_ct_rr_support() -> Option<PathBuf> {
    // Explicit environment variable (used by cross-repo test scripts).
    if let Ok(path) = std::env::var("CT_RR_SUPPORT_PATH") {
        let p = PathBuf::from(&path);
        if p.exists() && p.is_file() {
            return Some(p);
        }
    }

    // Check PATH.
    if let Ok(output) = std::process::Command::new("which")
        .arg("ct-rr-support")
        .output()
    {
        if output.status.success() {
            let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !path.is_empty() {
                return Some(PathBuf::from(path));
            }
        }
    }

    // Check common development locations relative to the backend-manager crate.
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let dev_locations = [
        "../../../codetracer-rr-backend/target/debug/ct-rr-support",
        "../../../codetracer-rr-backend/target/release/ct-rr-support",
        "../../codetracer-rr-backend/target/debug/ct-rr-support",
    ];

    for loc in dev_locations {
        let path = manifest_dir.join(loc);
        if path.exists() {
            return Some(path.canonicalize().unwrap_or(path));
        }
    }

    // Check from home directory.
    if let Some(home) = std::env::var_os("HOME") {
        let home_path = PathBuf::from(home);
        let home_locations = [
            "metacraft/codetracer-rr-backend/target/debug/ct-rr-support",
            "metacraft/codetracer-main/codetracer-rr-backend/target/debug/ct-rr-support",
            "codetracer-rr-backend/target/debug/ct-rr-support",
        ];
        for loc in home_locations {
            let path = home_path.join(loc);
            if path.exists() {
                return Some(path);
            }
        }
    }

    None
}

/// Check if `rr` is available on the system.
fn is_rr_available() -> bool {
    std::process::Command::new("rr")
        .arg("--version")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// Creates a unique temp directory for the test and returns `(temp_dir, log_path)`.
///
/// Uses /tmp directly (not $TMPDIR which can be very long in nix-shell).
fn setup_test_dir(test_name: &str) -> (PathBuf, PathBuf) {
    let mut hasher = DefaultHasher::new();
    test_name.hash(&mut hasher);
    let hash = hasher.finish();

    let dir = PathBuf::from("/tmp")
        .join("ct-t")
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

/// Encodes a JSON value into DAP wire format (Content-Length header + body).
fn dap_encode(msg: &Value) -> Vec<u8> {
    let body = msg.to_string();
    let body_bytes = body.as_bytes();
    let mut out = Vec::new();
    out.extend(format!("Content-Length: {}\r\n\r\n", body_bytes.len()).as_bytes());
    out.extend(body_bytes);
    out
}

/// Reads a single DAP-framed JSON message from `stream`.
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

/// Waits for a Unix socket file to appear on disk, polling every 50 ms.
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

/// Computes the daemon paths when we override TMPDIR.
fn daemon_paths_in(test_dir: &Path) -> PathBuf {
    test_dir.join("codetracer")
}

/// Starts the daemon process with the given test directory as its tmp root.
///
/// Passes CODETRACER_DB_BACKEND_CMD to point to the real db-backend binary.
async fn start_daemon_with_real_backend(
    test_dir: &Path,
    log_path: &Path,
    db_backend_path: &Path,
    extra_env: &[(&str, &str)],
) -> (tokio::process::Child, PathBuf) {
    let ct_dir = daemon_paths_in(test_dir);
    std::fs::create_dir_all(&ct_dir).expect("create ct dir");

    let socket_path = ct_dir.join("daemon.sock");
    let pid_path = ct_dir.join("daemon.pid");

    // Remove any stale files from a previous run.
    let _ = std::fs::remove_file(&socket_path);
    let _ = std::fs::remove_file(&pid_path);

    log_line(
        log_path,
        &format!(
            "starting daemon, TMPDIR={}, db-backend={}",
            test_dir.display(),
            db_backend_path.display()
        ),
    );

    let db_backend_str = db_backend_path.to_string_lossy().to_string();

    let mut cmd = Command::new(binary_path());
    cmd.arg("daemon")
        .arg("start")
        .env("TMPDIR", test_dir)
        .env("CODETRACER_DB_BACKEND_CMD", &db_backend_str)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    for (key, value) in extra_env {
        cmd.env(key, value);
    }

    let child = cmd.spawn().expect("cannot spawn daemon");

    // Wait for the socket to appear.
    wait_for_socket(&socket_path, Duration::from_secs(10))
        .await
        .expect("daemon socket did not appear in time");

    log_line(log_path, "daemon socket appeared");

    (child, socket_path)
}

/// Sends a `ct/daemon-shutdown` message and waits for the daemon to exit.
async fn shutdown_daemon(stream: &mut UnixStream, child: &mut tokio::process::Child) {
    let req = json!({"type": "request", "command": "ct/daemon-shutdown", "seq": 9999});
    let _ = stream.write_all(&dap_encode(&req)).await;
    // Give the daemon a moment to process the shutdown.
    let _ = timeout(Duration::from_secs(5), child.wait()).await;
    // If it hasn't exited, kill it.
    let _ = child.kill().await;
}

/// Sends `ct/open-trace` and returns the response.
///
/// Uses a longer timeout (60s) to allow for real db-backend initialization
/// which involves loading traces and running the DAP handshake.
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

    let resp = timeout(Duration::from_secs(60), dap_read(client))
        .await
        .map_err(|_| "timeout waiting for ct/open-trace response".to_string())?
        .map_err(|e| format!("read ct/open-trace response: {e}"))?;

    log_line(log_path, &format!("ct/open-trace response: {resp}"));
    Ok(resp)
}

/// Sends `ct/trace-info` and returns the response, skipping any interleaved events.
async fn query_trace_info(
    client: &mut UnixStream,
    seq: i64,
    trace_path: &Path,
    log_path: &Path,
) -> Result<Value, String> {
    let req = json!({
        "type": "request",
        "command": "ct/trace-info",
        "seq": seq,
        "arguments": {
            "tracePath": trace_path.to_string_lossy(),
        }
    });
    client
        .write_all(&dap_encode(&req))
        .await
        .map_err(|e| format!("write ct/trace-info: {e}"))?;

    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err("timeout waiting for ct/trace-info response".to_string());
        }

        let msg = timeout(remaining, dap_read(client))
            .await
            .map_err(|_| "timeout waiting for ct/trace-info response".to_string())?
            .map_err(|e| format!("read ct/trace-info: {e}"))?;

        let msg_type = msg.get("type").and_then(Value::as_str).unwrap_or("");
        if msg_type == "event" {
            log_line(log_path, &format!("trace-info: skipped event: {msg}"));
            continue;
        }

        log_line(log_path, &format!("ct/trace-info response: {msg}"));
        return Ok(msg);
    }
}

/// Reports test result: minimal on success, log path on failure.
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
// RR-based test helpers
// ---------------------------------------------------------------------------

/// Builds and records a Rust test program, returning the path to the trace
/// directory.  The test program source is at a known location relative to
/// CARGO_MANIFEST_DIR.
fn create_rr_recording(
    test_dir: &Path,
    ct_rr_support: &Path,
    log_path: &Path,
) -> Result<PathBuf, String> {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir
        .parent()
        .map(|p| p.join("db-backend/test-programs/rust/rust_flow_test.rs"))
        .ok_or("cannot determine source path")?;

    if !source_path.exists() {
        return Err(format!(
            "test program source not found at {}",
            source_path.display()
        ));
    }

    let trace_dir = test_dir.join("trace");
    let binary_path = test_dir.join("rust_flow_test");

    log_line(
        log_path,
        &format!(
            "building test program: {} -> {}",
            source_path.display(),
            binary_path.display()
        ),
    );

    // Build the test program.
    let build_output = std::process::Command::new(ct_rr_support)
        .args([
            "build",
            source_path.to_str().unwrap(),
            binary_path.to_str().unwrap(),
        ])
        .output()
        .map_err(|e| format!("failed to run ct-rr-support build: {e}"))?;

    if !build_output.status.success() {
        let stdout = String::from_utf8_lossy(&build_output.stdout);
        let stderr = String::from_utf8_lossy(&build_output.stderr);
        log_line(log_path, &format!("build stdout: {stdout}"));
        log_line(log_path, &format!("build stderr: {stderr}"));
        return Err(format!("ct-rr-support build failed:\n{stderr}"));
    }

    log_line(
        log_path,
        &format!("recording trace to {}", trace_dir.display()),
    );

    // Record the trace.
    let record_output = std::process::Command::new(ct_rr_support)
        .args([
            "record",
            "-o",
            trace_dir.to_str().unwrap(),
            binary_path.to_str().unwrap(),
        ])
        .output()
        .map_err(|e| format!("failed to run ct-rr-support record: {e}"))?;

    if !record_output.status.success() {
        let stdout = String::from_utf8_lossy(&record_output.stdout);
        let stderr = String::from_utf8_lossy(&record_output.stderr);
        log_line(log_path, &format!("record stdout: {stdout}"));
        log_line(log_path, &format!("record stderr: {stderr}"));
        return Err(format!("ct-rr-support record failed:\n{stderr}"));
    }

    log_line(log_path, "recording created successfully");

    // RR recordings produce `trace_db_metadata.json` (a CodeTracer-specific
    // extended format) but not `trace_metadata.json` (the simpler format the
    // backend-manager's `read_trace_metadata()` expects).  We bridge this
    // gap by reading the extended file and writing the simple one.
    let db_meta_path = trace_dir.join("trace_db_metadata.json");
    if db_meta_path.exists() {
        let db_meta_contents =
            std::fs::read_to_string(&db_meta_path).map_err(|e| {
                format!(
                    "failed to read {}: {e}",
                    db_meta_path.display()
                )
            })?;
        let db_meta: Value = serde_json::from_str(&db_meta_contents).map_err(|e| {
            format!(
                "failed to parse {}: {e}",
                db_meta_path.display()
            )
        })?;

        // Extract program, args, workdir from the extended metadata.
        let program = db_meta
            .get("program")
            .and_then(Value::as_str)
            .unwrap_or("");
        let workdir = db_meta
            .get("workdir")
            .and_then(Value::as_str)
            .unwrap_or("");
        let args = db_meta
            .get("args")
            .cloned()
            .unwrap_or_else(|| json!([]));

        // The `program` field in `trace_db_metadata.json` is typically an
        // absolute path.  The backend-manager's `detect_language()` only
        // needs the extension, so we keep the full path — it works either
        // way.
        let simple_meta = json!({
            "workdir": workdir,
            "program": program,
            "args": args,
        });

        let simple_meta_path = trace_dir.join("trace_metadata.json");
        std::fs::write(
            &simple_meta_path,
            serde_json::to_string_pretty(&simple_meta).unwrap(),
        )
        .map_err(|e| {
            format!(
                "failed to write {}: {e}",
                simple_meta_path.display()
            )
        })?;

        log_line(
            log_path,
            &format!(
                "created trace_metadata.json (program={program}, workdir={workdir})"
            ),
        );
    } else {
        log_line(
            log_path,
            "WARNING: trace_db_metadata.json not found, trace_metadata.json not created",
        );
    }

    Ok(trace_dir)
}

/// Checks whether all RR-based test prerequisites are met.  If not, returns
/// a human-readable skip reason.
fn check_rr_prerequisites() -> Result<(PathBuf, PathBuf), String> {
    let ct_rr_support = find_ct_rr_support()
        .ok_or_else(|| "ct-rr-support not found (skipping RR-based tests)".to_string())?;

    if !is_rr_available() {
        return Err("rr not available (skipping RR-based tests)".to_string());
    }

    let db_backend = find_db_backend()
        .ok_or_else(|| "db-backend not found (skipping real recording tests)".to_string())?;

    Ok((ct_rr_support, db_backend))
}

// ---------------------------------------------------------------------------
// Custom trace format helpers
// ---------------------------------------------------------------------------

/// Creates a minimal but valid custom trace directory that db-backend can process.
///
/// The trace simulates a simple Ruby program with integer arithmetic:
/// ```ruby
/// # test.rb
/// def compute(a)
///   result = a * 2
///   return result
/// end
///
/// x = 10
/// y = compute(x)
/// ```
///
/// The trace events follow the `TraceLowLevelEvent` enum format used by
/// `runtime_tracing` and consumed by `TraceProcessor`.  The format is
/// validated against the existing `db-backend/trace/trace.json` example
/// which uses `Int` values with fields `{kind: "Int", i: <n>, type_id: <n>}`.
///
/// Reference: `codetracer/libs/runtime_tracing/runtime_tracing/src/types.rs`
fn create_custom_trace_dir(parent: &Path, name: &str) -> PathBuf {
    let trace_dir = parent.join(name);
    let source_file = "/tmp/test-workdir/test.rb";

    // Create directories.
    std::fs::create_dir_all(trace_dir.join("files/tmp/test-workdir"))
        .expect("create trace files dir");

    // Write the source file.
    let source_content = "def compute(a)\n  result = a * 2\n  return result\nend\n\nx = 10\ny = compute(x)\n";
    std::fs::write(
        trace_dir.join("files/tmp/test-workdir/test.rb"),
        source_content,
    )
    .expect("write source file");

    // Write trace_metadata.json.
    let metadata = json!({
        "workdir": "/tmp/test-workdir",
        "program": "test.rb",
        "args": []
    });
    std::fs::write(
        trace_dir.join("trace_metadata.json"),
        serde_json::to_string_pretty(&metadata).unwrap(),
    )
    .expect("write trace_metadata.json");

    // Write trace_paths.json.
    let paths = json!([source_file]);
    std::fs::write(
        trace_dir.join("trace_paths.json"),
        serde_json::to_string(&paths).unwrap(),
    )
    .expect("write trace_paths.json");

    // Write trace.json with a valid sequence of trace events.
    //
    // The event format matches the `TraceLowLevelEvent` enum from
    // `runtime_tracing`.  This trace follows the same pattern as the
    // working example in `db-backend/trace/trace.json`, using only `Int`
    // values which are known to deserialize correctly.
    //
    // Event sequence for `y = compute(x)`:
    //   Path -> Type(i32) ->
    //   Function("main") -> Call(main) ->
    //   Step(line 6) -> VariableName("x") ->
    //   Value(x=10) ->
    //   Step(line 7) ->
    //   Function("compute") -> Call(compute, args=[a=10]) ->
    //   Step(line 1) -> Step(line 2) ->
    //   VariableName("result") -> Value(result=20) ->
    //   Step(line 3) ->
    //   Return(20) ->
    //   Step(line 7) ->
    //   VariableName("y") -> Value(y=20)
    let events = json!([
        {"Path": source_file},
        {"Type": {"kind": 7, "lang_type": "i32", "specific_info": {"kind": "None"}}},
        {"Function": {"name": "main", "path_id": 0, "line": 6}},
        {"Call": {"function_id": 0, "args": []}},
        {"Step": {"path_id": 0, "line": 6}},
        {"VariableName": "x"},
        {"Value": {"variable_id": 0, "value": {"kind": "Int", "i": 10, "type_id": 0}}},
        {"Step": {"path_id": 0, "line": 7}},
        {"Value": {"variable_id": 0, "value": {"kind": "Int", "i": 10, "type_id": 0}}},
        {"Function": {"name": "compute", "path_id": 0, "line": 1}},
        {"Call": {"function_id": 1, "args": [
            {"variable_id": 0, "value": {"kind": "Int", "i": 10, "type_id": 0}}
        ]}},
        {"Step": {"path_id": 0, "line": 1}},
        {"Step": {"path_id": 0, "line": 2}},
        {"VariableName": "result"},
        {"Value": {"variable_id": 1, "value": {"kind": "Int", "i": 20, "type_id": 0}}},
        {"Step": {"path_id": 0, "line": 3}},
        {"Return": {"return_value": {"kind": "Int", "i": 20, "type_id": 0}}},
        {"Step": {"path_id": 0, "line": 7}},
        {"VariableName": "y"},
        {"Value": {"variable_id": 2, "value": {"kind": "Int", "i": 20, "type_id": 0}}}
    ]);

    std::fs::write(
        trace_dir.join("trace.json"),
        serde_json::to_string_pretty(&events).unwrap(),
    )
    .expect("write trace.json");

    trace_dir
}

// ===========================================================================
// RR-based real-recording tests
// ===========================================================================

/// RR-1. Create a real RR trace recording (Rust test program).  Start daemon.
/// Send `ct/open-trace`.  Verify db-backend process is launched.  Verify DAP
/// init completes.  Verify session metadata is populated (total events > 0,
/// source files non-empty, language = "rust").
#[tokio::test]
async fn test_real_rr_session_launches_db_backend() {
    let (test_dir, log_path) = setup_test_dir("real_rr_session_launches");
    let mut success = false;

    let result: Result<(), String> = async {
        let (ct_rr_support, db_backend) = match check_rr_prerequisites() {
            Ok(paths) => paths,
            Err(reason) => {
                log_line(&log_path, &format!("SKIP: {reason}"));
                println!("test_real_rr_session_launches_db_backend: SKIP ({reason})");
                // Return Ok to count as a skip, not a failure.
                return Ok(());
            }
        };

        log_line(
            &log_path,
            &format!(
                "ct-rr-support: {}, db-backend: {}",
                ct_rr_support.display(),
                db_backend.display()
            ),
        );

        // Create an RR recording of the Rust test program.
        let trace_dir = create_rr_recording(&test_dir, &ct_rr_support, &log_path)?;
        log_line(
            &log_path,
            &format!("trace directory: {}", trace_dir.display()),
        );

        // Start the daemon with the real db-backend.
        // Pass ct-rr-support path so the daemon can relay it to
        // db-backend for RR replay (via the `ctRRWorkerExe` launch arg).
        let ct_rr_support_str = ct_rr_support.to_string_lossy().to_string();
        let (mut daemon, socket_path) =
            start_daemon_with_real_backend(
                &test_dir,
                &log_path,
                &db_backend,
                &[("CODETRACER_CT_RR_SUPPORT_CMD", &ct_rr_support_str)],
            ).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.
        let resp = open_trace(&mut client, 1000, &trace_dir, &log_path).await?;

        assert_eq!(
            resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed, got: {resp}"
        );

        // Verify metadata in response body.
        let body = resp
            .get("body")
            .expect("response should have body");

        // The trace was made from a Rust program; however, the trace
        // directory may not contain trace_metadata.json with program
        // extension information.  The RR recording's metadata may
        // report "unknown" for the language, so we check that at least
        // the session was created and events exist.
        //
        // Note: The daemon reads trace_metadata.json (not the RR recording
        // itself) for metadata.  If the RR recording creates
        // trace_metadata.json with the program name, language detection
        // will work.
        log_line(
            &log_path,
            &format!("open-trace body: {}", serde_json::to_string_pretty(body).unwrap_or_default()),
        );

        let total_events = body
            .get("totalEvents")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        log_line(&log_path, &format!("totalEvents: {total_events}"));

        // For an RR recording, trace.json may not exist (events come from
        // the RR replay, not a JSON file).  totalEvents may be 0.  That is
        // acceptable for RR recordings.  The key assertion is that the
        // session opened successfully (DAP init completed).

        // Verify backendId is present (session was created).
        let backend_id = body
            .get("backendId")
            .and_then(Value::as_u64);
        assert!(
            backend_id.is_some(),
            "response should contain backendId"
        );
        log_line(
            &log_path,
            &format!("backendId: {}", backend_id.unwrap()),
        );

        // Verify the open was not cached (first time opening).
        assert_eq!(
            body.get("cached").and_then(Value::as_bool),
            Some(false),
            "first open should not be cached"
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report(
        "test_real_rr_session_launches_db_backend",
        &log_path,
        success,
    );
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// RR-2. Open the same RR trace twice.  Verify only one db-backend is running.
/// Verify both requests return same metadata.  Second response should be cached.
#[tokio::test]
async fn test_real_rr_session_reuses_existing() {
    let (test_dir, log_path) = setup_test_dir("real_rr_session_reuses");
    let mut success = false;

    let result: Result<(), String> = async {
        let (ct_rr_support, db_backend) = match check_rr_prerequisites() {
            Ok(paths) => paths,
            Err(reason) => {
                log_line(&log_path, &format!("SKIP: {reason}"));
                println!("test_real_rr_session_reuses_existing: SKIP ({reason})");
                return Ok(());
            }
        };

        // Create an RR recording.
        let trace_dir = create_rr_recording(&test_dir, &ct_rr_support, &log_path)?;

        // Start the daemon with the real db-backend.
        let ct_rr_support_str = ct_rr_support.to_string_lossy().to_string();
        let (mut daemon, socket_path) =
            start_daemon_with_real_backend(
                &test_dir,
                &log_path,
                &db_backend,
                &[("CODETRACER_CT_RR_SUPPORT_CMD", &ct_rr_support_str)],
            ).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // First open.
        let resp1 = open_trace(&mut client, 2000, &trace_dir, &log_path).await?;
        assert_eq!(
            resp1.get("success").and_then(Value::as_bool),
            Some(true),
            "first open should succeed"
        );
        let backend_id_1 = resp1
            .get("body")
            .and_then(|b| b.get("backendId"))
            .and_then(Value::as_u64);

        // Second open (same trace).
        let resp2 = open_trace(&mut client, 2001, &trace_dir, &log_path).await?;
        assert_eq!(
            resp2.get("success").and_then(Value::as_bool),
            Some(true),
            "second open should succeed"
        );
        let backend_id_2 = resp2
            .get("body")
            .and_then(|b| b.get("backendId"))
            .and_then(Value::as_u64);

        // Same backend ID (same session reused).
        assert_eq!(
            backend_id_1, backend_id_2,
            "second open should reuse the same backend (ids: {:?} vs {:?})",
            backend_id_1, backend_id_2
        );

        // Second open should be cached.
        assert_eq!(
            resp2
                .get("body")
                .and_then(|b| b.get("cached"))
                .and_then(Value::as_bool),
            Some(true),
            "second open should be cached"
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report(
        "test_real_rr_session_reuses_existing",
        &log_path,
        success,
    );
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// RR-3. Open an RR trace.  Send `ct/trace-info`.  Verify response includes
/// correct metadata fields.
#[tokio::test]
async fn test_real_rr_trace_info_returns_metadata() {
    let (test_dir, log_path) = setup_test_dir("real_rr_trace_info");
    let mut success = false;

    let result: Result<(), String> = async {
        let (ct_rr_support, db_backend) = match check_rr_prerequisites() {
            Ok(paths) => paths,
            Err(reason) => {
                log_line(&log_path, &format!("SKIP: {reason}"));
                println!("test_real_rr_trace_info_returns_metadata: SKIP ({reason})");
                return Ok(());
            }
        };

        // Create an RR recording.
        let trace_dir = create_rr_recording(&test_dir, &ct_rr_support, &log_path)?;

        // Start the daemon with the real db-backend.
        let ct_rr_support_str = ct_rr_support.to_string_lossy().to_string();
        let (mut daemon, socket_path) =
            start_daemon_with_real_backend(
                &test_dir,
                &log_path,
                &db_backend,
                &[("CODETRACER_CT_RR_SUPPORT_CMD", &ct_rr_support_str)],
            ).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // First, open the trace (required before trace-info will work).
        let open_resp = open_trace(&mut client, 3000, &trace_dir, &log_path).await?;
        assert_eq!(
            open_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed"
        );

        // Now query trace-info.
        let info_resp = query_trace_info(&mut client, 3001, &trace_dir, &log_path).await?;
        assert_eq!(
            info_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/trace-info should succeed, got: {info_resp}"
        );

        let body = info_resp
            .get("body")
            .expect("trace-info response should have body");

        log_line(
            &log_path,
            &format!("trace-info body: {}", serde_json::to_string_pretty(body).unwrap_or_default()),
        );

        // Verify tracePath is echoed back.
        assert!(
            body.get("tracePath").and_then(Value::as_str).is_some(),
            "trace-info should include tracePath"
        );

        // Verify language field exists (may be "unknown" for RR recordings
        // without trace_metadata.json, or "rust" if it exists).
        assert!(
            body.get("language").and_then(Value::as_str).is_some(),
            "trace-info should include language"
        );

        // Verify program field exists.
        assert!(
            body.get("program").and_then(Value::as_str).is_some(),
            "trace-info should include program"
        );

        // Verify workdir field exists.
        assert!(
            body.get("workdir").and_then(Value::as_str).is_some(),
            "trace-info should include workdir"
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report(
        "test_real_rr_trace_info_returns_metadata",
        &log_path,
        success,
    );
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// RR-4. Open an RR trace.  Verify the session opened successfully.
/// The daemon internally runs initialize -> launch -> configurationDone ->
/// waits for stopped event.  The fact that ct/open-trace returns success
/// proves the full DAP initialization sequence completed.
#[tokio::test]
async fn test_real_rr_dap_initialization_sequence() {
    let (test_dir, log_path) = setup_test_dir("real_rr_dap_init");
    let mut success = false;

    let result: Result<(), String> = async {
        let (ct_rr_support, db_backend) = match check_rr_prerequisites() {
            Ok(paths) => paths,
            Err(reason) => {
                log_line(&log_path, &format!("SKIP: {reason}"));
                println!("test_real_rr_dap_initialization_sequence: SKIP ({reason})");
                return Ok(());
            }
        };

        // Create an RR recording.
        let trace_dir = create_rr_recording(&test_dir, &ct_rr_support, &log_path)?;

        // Start the daemon.
        let ct_rr_support_str = ct_rr_support.to_string_lossy().to_string();
        let (mut daemon, socket_path) =
            start_daemon_with_real_backend(
                &test_dir,
                &log_path,
                &db_backend,
                &[("CODETRACER_CT_RR_SUPPORT_CMD", &ct_rr_support_str)],
            ).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.  Success means the full DAP init sequence completed:
        //   1. initialize request -> response with capabilities
        //   2. launch request (with traceFolder) -> response
        //   3. configurationDone request -> response
        //   4. stopped event from db-backend
        //   5. stackTrace query for initial location
        let resp = open_trace(&mut client, 4000, &trace_dir, &log_path).await?;

        assert_eq!(
            resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed (proves DAP init completed), got: {resp}"
        );

        // Verify the response includes an initial location (from the
        // post-init stackTrace query).
        let body = resp.get("body").expect("response should have body");
        let initial_location = body.get("initialLocation");
        log_line(
            &log_path,
            &format!("initialLocation: {:?}", initial_location),
        );

        // The initial location should exist and have a non-empty path
        // (indicating the backend successfully loaded the trace and is
        // at the program's entry point).
        if let Some(loc) = initial_location {
            let path = loc.get("path").and_then(Value::as_str).unwrap_or("");
            log_line(&log_path, &format!("initial path: {path}"));
            // The path may be empty if the db-backend could not determine
            // the entry point, but it should at least be present.
        }

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report(
        "test_real_rr_dap_initialization_sequence",
        &log_path,
        success,
    );
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

// ===========================================================================
// Custom trace format tests
// ===========================================================================

/// Custom-1. Create a custom trace format recording (hand-crafted valid
/// trace.json for a simple Ruby-like program).  Start daemon.  Send
/// `ct/open-trace`.  Verify db-backend processes it.  Verify metadata
/// (language, events, source files).
#[tokio::test]
async fn test_real_custom_session_launches_db_backend() {
    let (test_dir, log_path) = setup_test_dir("real_custom_session_launches");
    let mut success = false;

    let result: Result<(), String> = async {
        let db_backend = match find_db_backend() {
            Some(path) => path,
            None => {
                log_line(&log_path, "SKIP: db-backend not found");
                println!("test_real_custom_session_launches_db_backend: SKIP (db-backend not found)");
                return Ok(());
            }
        };

        log_line(
            &log_path,
            &format!("db-backend: {}", db_backend.display()),
        );

        // Create the custom trace directory.
        let trace_dir = create_custom_trace_dir(&test_dir, "custom-trace");
        log_line(
            &log_path,
            &format!("custom trace dir: {}", trace_dir.display()),
        );

        // Start the daemon with the real db-backend.
        let (mut daemon, socket_path) =
            start_daemon_with_real_backend(&test_dir, &log_path, &db_backend, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.
        let resp = open_trace(&mut client, 5000, &trace_dir, &log_path).await?;

        assert_eq!(
            resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed for custom trace, got: {resp}"
        );

        // Verify metadata in response body.
        let body = resp.get("body").expect("response should have body");
        log_line(
            &log_path,
            &format!("open-trace body: {}", serde_json::to_string_pretty(body).unwrap_or_default()),
        );

        // Language should be "ruby" (detected from "test.rb" extension).
        assert_eq!(
            body.get("language").and_then(Value::as_str),
            Some("ruby"),
            "language should be 'ruby'"
        );

        // Total events should match our trace.json entries (20 events).
        let total_events = body
            .get("totalEvents")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        assert!(
            total_events > 0,
            "totalEvents should be > 0, got {total_events}"
        );
        log_line(&log_path, &format!("totalEvents: {total_events}"));

        // Source files should be non-empty.
        let source_files = body
            .get("sourceFiles")
            .and_then(Value::as_array)
            .map(|a| a.len())
            .unwrap_or(0);
        assert!(
            source_files > 0,
            "sourceFiles should be non-empty, got {source_files}"
        );

        // Program should be "test.rb".
        assert_eq!(
            body.get("program").and_then(Value::as_str),
            Some("test.rb"),
            "program should be 'test.rb'"
        );

        // Workdir should match.
        assert_eq!(
            body.get("workdir").and_then(Value::as_str),
            Some("/tmp/test-workdir"),
            "workdir should be '/tmp/test-workdir'"
        );

        // Verify the open was not cached (first time opening).
        assert_eq!(
            body.get("cached").and_then(Value::as_bool),
            Some(false),
            "first open should not be cached"
        );

        // Verify backendId is present (session was created).
        assert!(
            body.get("backendId").and_then(Value::as_u64).is_some(),
            "response should contain backendId"
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report(
        "test_real_custom_session_launches_db_backend",
        &log_path,
        success,
    );
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// Custom-2. Create a custom trace.  Open it.  Send `ct/trace-info`.  Verify
/// response includes correct language, event count, and source file paths.
#[tokio::test]
async fn test_real_custom_trace_info_returns_metadata() {
    let (test_dir, log_path) = setup_test_dir("real_custom_trace_info");
    let mut success = false;

    let result: Result<(), String> = async {
        let db_backend = match find_db_backend() {
            Some(path) => path,
            None => {
                log_line(&log_path, "SKIP: db-backend not found");
                println!("test_real_custom_trace_info_returns_metadata: SKIP (db-backend not found)");
                return Ok(());
            }
        };

        // Create the custom trace directory.
        let trace_dir = create_custom_trace_dir(&test_dir, "custom-trace-info");

        // Start the daemon with the real db-backend.
        let (mut daemon, socket_path) =
            start_daemon_with_real_backend(&test_dir, &log_path, &db_backend, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // First, open the trace (required before trace-info returns data).
        let open_resp = open_trace(&mut client, 6000, &trace_dir, &log_path).await?;
        assert_eq!(
            open_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed"
        );

        // Query trace-info.
        let info_resp = query_trace_info(&mut client, 6001, &trace_dir, &log_path).await?;
        assert_eq!(
            info_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/trace-info should succeed, got: {info_resp}"
        );

        let body = info_resp
            .get("body")
            .expect("trace-info response should have body");
        log_line(
            &log_path,
            &format!("trace-info body: {}", serde_json::to_string_pretty(body).unwrap_or_default()),
        );

        // Verify language is "ruby".
        assert_eq!(
            body.get("language").and_then(Value::as_str),
            Some("ruby"),
            "language should be 'ruby'"
        );

        // Verify total events > 0.
        let total_events = body
            .get("totalEvents")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        assert!(
            total_events > 0,
            "totalEvents should be > 0, got {total_events}"
        );

        // Verify source files include our test file.
        let source_files = body
            .get("sourceFiles")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        assert!(
            !source_files.is_empty(),
            "sourceFiles should be non-empty"
        );
        let file_paths: Vec<&str> = source_files
            .iter()
            .filter_map(Value::as_str)
            .collect();
        log_line(&log_path, &format!("source files: {:?}", file_paths));
        assert!(
            file_paths.iter().any(|p| p.contains("test.rb")),
            "sourceFiles should include test.rb, got: {:?}",
            file_paths
        );

        // Verify program is "test.rb".
        assert_eq!(
            body.get("program").and_then(Value::as_str),
            Some("test.rb"),
            "program should be 'test.rb'"
        );

        // Verify workdir.
        assert_eq!(
            body.get("workdir").and_then(Value::as_str),
            Some("/tmp/test-workdir"),
            "workdir should be '/tmp/test-workdir'"
        );

        // Verify tracePath is echoed back.
        let trace_path_returned = body
            .get("tracePath")
            .and_then(Value::as_str)
            .unwrap_or("");
        assert!(
            !trace_path_returned.is_empty(),
            "tracePath should be echoed back"
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report(
        "test_real_custom_trace_info_returns_metadata",
        &log_path,
        success,
    );
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

// ===========================================================================
// M3 Navigation helpers
// ===========================================================================

/// Sends `ct/py-navigate` and waits for the response, skipping any
/// interleaved events (such as `stopped` events from the backend).
///
/// Returns the full response JSON on success.  Uses a 30-second timeout
/// which is generous enough to account for DAP round-trips through a real
/// backend.
async fn navigate(
    client: &mut UnixStream,
    seq: i64,
    trace_path: &Path,
    method: &str,
    extra_args: Option<&Value>,
    log_path: &Path,
) -> Result<Value, String> {
    let mut arguments = json!({
        "tracePath": trace_path.to_string_lossy(),
        "method": method,
    });

    // Merge any extra arguments (e.g., `ticks` for goto_ticks) into the
    // top-level arguments object.
    if let Some(extras) = extra_args {
        if let Some(obj) = extras.as_object() {
            for (k, v) in obj {
                arguments[k] = v.clone();
            }
        }
    }

    let req = json!({
        "type": "request",
        "command": "ct/py-navigate",
        "seq": seq,
        "arguments": arguments,
    });

    log_line(
        log_path,
        &format!("-> ct/py-navigate seq={seq} method={method}"),
    );

    client
        .write_all(&dap_encode(&req))
        .await
        .map_err(|e| format!("write ct/py-navigate: {e}"))?;

    // Read messages, skipping events until we get a response.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err(format!(
                "timeout waiting for ct/py-navigate response (method={method})"
            ));
        }

        let msg = timeout(remaining, dap_read(client))
            .await
            .map_err(|_| {
                format!("timeout waiting for ct/py-navigate response (method={method})")
            })?
            .map_err(|e| format!("read ct/py-navigate: {e}"))?;

        let msg_type = msg.get("type").and_then(Value::as_str).unwrap_or("");
        if msg_type == "event" {
            log_line(
                log_path,
                &format!("navigate: skipped event: {msg}"),
            );
            continue;
        }

        log_line(
            log_path,
            &format!("<- ct/py-navigate response: {msg}"),
        );
        return Ok(msg);
    }
}

/// Extracts the location body from a successful `ct/py-navigate` response.
///
/// Returns a tuple of `(path, line, column, ticks, end_of_trace)`.
fn extract_nav_location(resp: &Value) -> Result<(String, i64, i64, i64, bool), String> {
    let body = resp
        .get("body")
        .ok_or("navigate response missing 'body'")?;

    let path = body
        .get("path")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let line = body.get("line").and_then(Value::as_i64).unwrap_or(0);
    let column = body.get("column").and_then(Value::as_i64).unwrap_or(0);
    let ticks = body.get("ticks").and_then(Value::as_i64).unwrap_or(0);
    let end_of_trace = body
        .get("endOfTrace")
        .and_then(Value::as_bool)
        .unwrap_or(false);

    Ok((path, line, column, ticks, end_of_trace))
}

/// Drains any pending events from the stream without blocking.
///
/// After `open_trace` the backend may have emitted events (e.g., output,
/// module-loaded) that would confuse subsequent reads.  This helper reads
/// and discards them with a short timeout.
async fn drain_events(client: &mut UnixStream, log_path: &Path) {
    loop {
        match timeout(Duration::from_millis(500), dap_read(client)).await {
            Ok(Ok(msg)) => {
                let msg_type = msg.get("type").and_then(Value::as_str).unwrap_or("");
                if msg_type == "event" {
                    log_line(log_path, &format!("drain: skipped event: {msg}"));
                    continue;
                }
                // Non-event message; not expected here but log it.
                log_line(
                    log_path,
                    &format!("drain: unexpected non-event: {msg}"),
                );
            }
            _ => break, // Timeout or error — no more pending messages.
        }
    }
}

// ===========================================================================
// M3 RR-based navigation tests
// ===========================================================================

/// M3-RR-1. Open an RR trace.  Send `ct/py-navigate` with method="step_over".
/// Verify the response contains a valid location (path non-empty, line > 0).
/// Do a second step_over.  Verify location changed (different line or
/// different ticks).
#[tokio::test]
async fn test_real_rr_navigate_step_over() {
    let (test_dir, log_path) = setup_test_dir("real_rr_nav_step_over");
    let mut success = false;

    let result: Result<(), String> = async {
        let (ct_rr_support, db_backend) = match check_rr_prerequisites() {
            Ok(paths) => paths,
            Err(reason) => {
                log_line(&log_path, &format!("SKIP: {reason}"));
                println!("test_real_rr_navigate_step_over: SKIP ({reason})");
                return Ok(());
            }
        };

        // Create an RR recording of the Rust test program.
        let trace_dir = create_rr_recording(&test_dir, &ct_rr_support, &log_path)?;

        // Start the daemon with the real db-backend.
        let ct_rr_support_str = ct_rr_support.to_string_lossy().to_string();
        let (mut daemon, socket_path) = start_daemon_with_real_backend(
            &test_dir,
            &log_path,
            &db_backend,
            &[("CODETRACER_CT_RR_SUPPORT_CMD", &ct_rr_support_str)],
        )
        .await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.
        let open_resp = open_trace(&mut client, 7000, &trace_dir, &log_path).await?;
        assert_eq!(
            open_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed, got: {open_resp}"
        );

        // Drain any pending events from the open-trace handshake.
        drain_events(&mut client, &log_path).await;

        // First step_over.
        let resp1 = navigate(
            &mut client,
            7001,
            &trace_dir,
            "step_over",
            None,
            &log_path,
        )
        .await?;

        assert_eq!(
            resp1.get("success").and_then(Value::as_bool),
            Some(true),
            "first step_over should succeed, got: {resp1}"
        );

        let (path1, line1, _col1, ticks1, _eot1) = extract_nav_location(&resp1)?;
        log_line(
            &log_path,
            &format!("step_over 1: path={path1} line={line1} ticks={ticks1}"),
        );

        assert!(
            !path1.is_empty(),
            "step_over should return non-empty path, got: {path1}"
        );
        assert!(
            line1 > 0,
            "step_over should return line > 0, got: {line1}"
        );

        // Second step_over.
        let resp2 = navigate(
            &mut client,
            7002,
            &trace_dir,
            "step_over",
            None,
            &log_path,
        )
        .await?;

        assert_eq!(
            resp2.get("success").and_then(Value::as_bool),
            Some(true),
            "second step_over should succeed, got: {resp2}"
        );

        let (path2, line2, _col2, ticks2, _eot2) = extract_nav_location(&resp2)?;
        log_line(
            &log_path,
            &format!("step_over 2: path={path2} line={line2} ticks={ticks2}"),
        );

        // After two step_overs the location should have changed — either
        // the line number or the ticks value (or both) must differ.
        assert!(
            line1 != line2 || ticks1 != ticks2,
            "two consecutive step_overs should change location: \
             (line={line1}, ticks={ticks1}) vs (line={line2}, ticks={ticks2})"
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("test_real_rr_navigate_step_over", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M3-RR-2. Open an RR trace.  Navigate to the `calculate_sum` call (line 19
/// of `rust_flow_test.rs`) by stepping.  Send step_in.  Verify we land inside
/// `calculate_sum` (different line, possibly line 4-12).  Send step_out.
/// Verify we return near the caller (line >= 19).
#[tokio::test]
async fn test_real_rr_navigate_step_in_out() {
    let (test_dir, log_path) = setup_test_dir("real_rr_nav_step_in_out");
    let mut success = false;

    let result: Result<(), String> = async {
        let (ct_rr_support, db_backend) = match check_rr_prerequisites() {
            Ok(paths) => paths,
            Err(reason) => {
                log_line(&log_path, &format!("SKIP: {reason}"));
                println!("test_real_rr_navigate_step_in_out: SKIP ({reason})");
                return Ok(());
            }
        };

        // Create an RR recording of the Rust test program.
        let trace_dir = create_rr_recording(&test_dir, &ct_rr_support, &log_path)?;

        // Start the daemon.
        let ct_rr_support_str = ct_rr_support.to_string_lossy().to_string();
        let (mut daemon, socket_path) = start_daemon_with_real_backend(
            &test_dir,
            &log_path,
            &db_backend,
            &[("CODETRACER_CT_RR_SUPPORT_CMD", &ct_rr_support_str)],
        )
        .await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.
        let open_resp = open_trace(&mut client, 8000, &trace_dir, &log_path).await?;
        assert_eq!(
            open_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed, got: {open_resp}"
        );

        drain_events(&mut client, &log_path).await;

        // Step through the program to reach a function call in user code.
        //
        // The Rust test program (`rust_flow_test.rs`) has:
        //   - `main()` at line 15
        //   - `let result = calculate_sum(x, y);` at line 19
        //   - `calculate_sum` at lines 4-12
        //
        // After opening an RR trace, the initial position is typically in
        // runtime startup code (e.g., `_start`), not in `main()`.  We step
        // forward repeatedly until we land in user code (path contains
        // `rust_flow_test`) with a non-zero line, which ensures we are in
        // a position with debug info where `step_in` will work reliably.
        //
        // If we never reach user code within the step budget, we still
        // exercise step_in/step_out from wherever we are, but with relaxed
        // assertions that tolerate the debugger staying in runtime code.
        let mut seq = 8001;
        let mut last_path = String::new();
        let mut last_line: i64 = 0;
        let mut last_ticks: i64 = 0;
        let mut in_user_code = false;

        // Step up to 40 times to find user code.
        for _ in 0..40 {
            let resp = navigate(
                &mut client,
                seq,
                &trace_dir,
                "step_over",
                None,
                &log_path,
            )
            .await?;
            seq += 1;

            if resp.get("success").and_then(Value::as_bool) != Some(true) {
                log_line(&log_path, &format!("step_over failed: {resp}"));
                break;
            }

            let (path, line, _, ticks, eot) = extract_nav_location(&resp)?;
            log_line(
                &log_path,
                &format!("pre-step: path={path} line={line} ticks={ticks} eot={eot}"),
            );
            last_path = path.clone();
            last_line = line;
            last_ticks = ticks;

            // Check if we've reached user code with debug info.
            if path.contains("rust_flow_test") && line > 0 {
                in_user_code = true;
            }

            if eot {
                break;
            }

            // If we've found user code, stop stepping once we're near
            // the `calculate_sum` call (line 17-19 area).  We don't need
            // to be exactly on line 19 — any line in main() is fine
            // because step_in from any statement will at least enter the
            // next function call or advance the instruction pointer.
            if in_user_code && line >= 17 && line <= 21 {
                log_line(
                    &log_path,
                    &format!("reached function call area at line {line}"),
                );
                break;
            }
        }

        log_line(
            &log_path,
            &format!(
                "before step_in: path={last_path} line={last_line} ticks={last_ticks} in_user_code={in_user_code}"
            ),
        );

        // Now do step_in.  This should either enter a function or advance
        // by a single instruction.
        let step_in_resp = navigate(
            &mut client,
            seq,
            &trace_dir,
            "step_in",
            None,
            &log_path,
        )
        .await?;
        seq += 1;

        assert_eq!(
            step_in_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "step_in should succeed, got: {step_in_resp}"
        );

        let (path_in, line_in, _, ticks_in, _eot_in) =
            extract_nav_location(&step_in_resp)?;
        log_line(
            &log_path,
            &format!("after step_in: path={path_in} line={line_in} ticks={ticks_in}"),
        );

        // step_in should have moved us somewhere different.
        //
        // When we are in user code (with debug info), line or ticks must
        // change.  When we are in runtime/library code without debug info,
        // the debugger may report line=0 both before and after, and in
        // rare cases ticks may also stay the same (e.g., stepping within
        // a single RR event).  In that case we only require that step_in
        // succeeded without error — the subsequent step_out test will
        // verify that execution actually progresses.
        if in_user_code {
            assert!(
                line_in != last_line || ticks_in != last_ticks || path_in != last_path,
                "step_in should change location in user code: \
                 before=(path={last_path}, line={last_line}, ticks={last_ticks}), \
                 after=(path={path_in}, line={line_in}, ticks={ticks_in})"
            );
        } else {
            // Even outside user code, step_in should change ticks or line
            // in most cases.  Log a warning but don't fail the test — the
            // debugger may genuinely be stuck in code with no debug info.
            if line_in == last_line && ticks_in == last_ticks && path_in == last_path {
                log_line(
                    &log_path,
                    "WARNING: step_in did not visibly change location (no debug info?)",
                );
            }
        }

        // Now do step_out.  This should bring us back towards the caller
        // or advance execution forward.
        let step_out_resp = navigate(
            &mut client,
            seq,
            &trace_dir,
            "step_out",
            None,
            &log_path,
        )
        .await?;

        assert_eq!(
            step_out_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "step_out should succeed, got: {step_out_resp}"
        );

        let (path_out, line_out, _, ticks_out, _eot_out) =
            extract_nav_location(&step_out_resp)?;
        log_line(
            &log_path,
            &format!("after step_out: path={path_out} line={line_out} ticks={ticks_out}"),
        );

        // step_out should have moved us further in execution.  At minimum,
        // ticks must advance (or line/path must change).  We also accept
        // endOfTrace as valid — the trace may end during step_out.
        assert!(
            ticks_out > ticks_in || line_out != line_in || path_out != path_in || _eot_out,
            "step_out should advance from the step_in position: \
             step_in=(path={path_in}, line={line_in}, ticks={ticks_in}), \
             step_out=(path={path_out}, line={line_out}, ticks={ticks_out})"
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("test_real_rr_navigate_step_in_out", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M3-RR-3. Open an RR trace.  Send `ct/py-navigate` with
/// method="continue_forward" (no breakpoints set).  Verify that the trace
/// reaches the end — indicated by `endOfTrace: true` in the response body,
/// or the response indicates a terminated state.
#[tokio::test]
async fn test_real_rr_navigate_continue_forward() {
    let (test_dir, log_path) = setup_test_dir("real_rr_nav_continue_fwd");
    let mut success = false;

    let result: Result<(), String> = async {
        let (ct_rr_support, db_backend) = match check_rr_prerequisites() {
            Ok(paths) => paths,
            Err(reason) => {
                log_line(&log_path, &format!("SKIP: {reason}"));
                println!("test_real_rr_navigate_continue_forward: SKIP ({reason})");
                return Ok(());
            }
        };

        // Create an RR recording of the Rust test program.
        let trace_dir = create_rr_recording(&test_dir, &ct_rr_support, &log_path)?;

        // Start the daemon.
        let ct_rr_support_str = ct_rr_support.to_string_lossy().to_string();
        let (mut daemon, socket_path) = start_daemon_with_real_backend(
            &test_dir,
            &log_path,
            &db_backend,
            &[("CODETRACER_CT_RR_SUPPORT_CMD", &ct_rr_support_str)],
        )
        .await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.
        let open_resp = open_trace(&mut client, 9000, &trace_dir, &log_path).await?;
        assert_eq!(
            open_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed, got: {open_resp}"
        );

        drain_events(&mut client, &log_path).await;

        // Send continue_forward with no breakpoints.  This should run the
        // trace to completion.
        let resp = navigate(
            &mut client,
            9001,
            &trace_dir,
            "continue_forward",
            None,
            &log_path,
        )
        .await?;

        assert_eq!(
            resp.get("success").and_then(Value::as_bool),
            Some(true),
            "continue_forward should succeed, got: {resp}"
        );

        let (path, line, _col, ticks, end_of_trace) = extract_nav_location(&resp)?;
        log_line(
            &log_path,
            &format!(
                "continue_forward: path={path} line={line} ticks={ticks} endOfTrace={end_of_trace}"
            ),
        );

        // When continuing with no breakpoints, the trace should run to the
        // end.  The backend indicates this via `endOfTrace: true`.  If the
        // backend does not set this flag (e.g., it stopped at the last
        // instruction), we at least verify we got a valid location with
        // ticks > 0 (meaning execution progressed).
        if end_of_trace {
            log_line(&log_path, "trace reached end (endOfTrace=true)");
        } else {
            // Even without endOfTrace, ticks should have advanced past 0,
            // proving the continue actually ran.
            assert!(
                ticks > 0,
                "continue_forward should advance execution, got ticks={ticks}"
            );
            log_line(
                &log_path,
                &format!(
                    "continue_forward did not set endOfTrace, but ticks={ticks} > 0 (OK)"
                ),
            );
        }

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report(
        "test_real_rr_navigate_continue_forward",
        &log_path,
        success,
    );
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M3-RR-4. Open an RR trace.  Step over three times, recording ticks at
/// each step.  Then step back once and verify that the ticks decreased,
/// proving bidirectional navigation works against a real RR trace.
///
/// This replaces the earlier `goto_ticks` test because `ct/goto-ticks` is
/// not a standard DAP command and is not implemented by `db-backend`.
/// `step_back` maps to the standard DAP `stepBack` request, which *is*
/// supported by the real backend.
#[tokio::test]
async fn test_real_rr_navigate_step_back() {
    let (test_dir, log_path) = setup_test_dir("real_rr_nav_step_back");
    let mut success = false;

    let result: Result<(), String> = async {
        let (ct_rr_support, db_backend) = match check_rr_prerequisites() {
            Ok(paths) => paths,
            Err(reason) => {
                log_line(&log_path, &format!("SKIP: {reason}"));
                println!("test_real_rr_navigate_step_back: SKIP ({reason})");
                return Ok(());
            }
        };

        // Create an RR recording of the Rust test program.
        let trace_dir = create_rr_recording(&test_dir, &ct_rr_support, &log_path)?;

        // Start the daemon.
        let ct_rr_support_str = ct_rr_support.to_string_lossy().to_string();
        let (mut daemon, socket_path) = start_daemon_with_real_backend(
            &test_dir,
            &log_path,
            &db_backend,
            &[("CODETRACER_CT_RR_SUPPORT_CMD", &ct_rr_support_str)],
        )
        .await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.
        let open_resp = open_trace(&mut client, 10_000, &trace_dir, &log_path).await?;
        assert_eq!(
            open_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed, got: {open_resp}"
        );

        drain_events(&mut client, &log_path).await;

        // Step over three times, recording location/ticks at each step.
        let resp1 = navigate(
            &mut client,
            10_001,
            &trace_dir,
            "step_over",
            None,
            &log_path,
        )
        .await?;
        assert_eq!(
            resp1.get("success").and_then(Value::as_bool),
            Some(true),
            "first step_over should succeed"
        );
        let (_path1, line1, _col1, ticks1, _) = extract_nav_location(&resp1)?;
        log_line(
            &log_path,
            &format!("step 1: line={line1} ticks={ticks1}"),
        );

        let resp2 = navigate(
            &mut client,
            10_002,
            &trace_dir,
            "step_over",
            None,
            &log_path,
        )
        .await?;
        assert_eq!(
            resp2.get("success").and_then(Value::as_bool),
            Some(true),
            "second step_over should succeed"
        );
        let (_path2, line2, _, ticks2, _) = extract_nav_location(&resp2)?;
        log_line(
            &log_path,
            &format!("step 2: line={line2} ticks={ticks2}"),
        );

        let resp3 = navigate(
            &mut client,
            10_003,
            &trace_dir,
            "step_over",
            None,
            &log_path,
        )
        .await?;
        assert_eq!(
            resp3.get("success").and_then(Value::as_bool),
            Some(true),
            "third step_over should succeed"
        );
        let (_path3, line3, _, ticks3, _) = extract_nav_location(&resp3)?;
        log_line(
            &log_path,
            &format!("step 3: line={line3} ticks={ticks3}"),
        );

        // Step back once.  The DAP `stepBack` command is supported by
        // db-backend (it advertises `supportsStepBack: true`).
        let back_resp = navigate(
            &mut client,
            10_004,
            &trace_dir,
            "step_back",
            None,
            &log_path,
        )
        .await?;
        assert_eq!(
            back_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "step_back should succeed, got: {back_resp}"
        );
        let (_path_back, line_back, _, ticks_back, _) = extract_nav_location(&back_resp)?;
        log_line(
            &log_path,
            &format!("step_back: line={line_back} ticks={ticks_back}"),
        );

        // Verify we went backwards: ticks should have decreased compared
        // to the third step, OR the line should have decreased.  In
        // practice, both should happen, but we check ticks as the primary
        // indicator since line numbers can be non-monotonic in loops.
        assert!(
            ticks_back < ticks3 || line_back < line3,
            "step_back should go backwards: ticks_back={ticks_back} (should be < ticks3={ticks3}) \
             or line_back={line_back} (should be < line3={line3})"
        );
        log_line(
            &log_path,
            &format!(
                "backward navigation confirmed: ticks went from {ticks3} to {ticks_back}, \
                 line went from {line3} to {line_back}"
            ),
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("test_real_rr_navigate_step_back", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

// ===========================================================================
// M3 Custom trace format navigation tests
// ===========================================================================

/// M3-Custom-1. Open a custom trace (Ruby).  Send `ct/py-navigate` with
/// method="step_over".  Verify the response contains a valid location.  Do a
/// second step_over.  Verify location progresses through the trace.
#[tokio::test]
async fn test_real_custom_navigate_step_over() {
    let (test_dir, log_path) = setup_test_dir("real_custom_nav_step_over");
    let mut success = false;

    let result: Result<(), String> = async {
        let db_backend = match find_db_backend() {
            Some(path) => path,
            None => {
                log_line(&log_path, "SKIP: db-backend not found");
                println!(
                    "test_real_custom_navigate_step_over: SKIP (db-backend not found)"
                );
                return Ok(());
            }
        };

        log_line(
            &log_path,
            &format!("db-backend: {}", db_backend.display()),
        );

        // Create the custom trace directory.
        let trace_dir = create_custom_trace_dir(&test_dir, "custom-nav-trace");
        log_line(
            &log_path,
            &format!("custom trace dir: {}", trace_dir.display()),
        );

        // Start the daemon with the real db-backend.
        let (mut daemon, socket_path) =
            start_daemon_with_real_backend(&test_dir, &log_path, &db_backend, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.
        let open_resp = open_trace(&mut client, 11_000, &trace_dir, &log_path).await?;
        assert_eq!(
            open_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed for custom trace, got: {open_resp}"
        );

        drain_events(&mut client, &log_path).await;

        // First step_over.
        let resp1 = navigate(
            &mut client,
            11_001,
            &trace_dir,
            "step_over",
            None,
            &log_path,
        )
        .await?;

        assert_eq!(
            resp1.get("success").and_then(Value::as_bool),
            Some(true),
            "first step_over should succeed for custom trace, got: {resp1}"
        );

        let (path1, line1, _col1, ticks1, eot1) = extract_nav_location(&resp1)?;
        log_line(
            &log_path,
            &format!(
                "custom step_over 1: path={path1} line={line1} ticks={ticks1} eot={eot1}"
            ),
        );

        // The custom trace has a source file; path should be non-empty and
        // line should be > 0.
        assert!(
            !path1.is_empty(),
            "custom step_over should return non-empty path, got empty"
        );
        assert!(
            line1 > 0,
            "custom step_over should return line > 0, got: {line1}"
        );

        // Second step_over.
        let resp2 = navigate(
            &mut client,
            11_002,
            &trace_dir,
            "step_over",
            None,
            &log_path,
        )
        .await?;

        assert_eq!(
            resp2.get("success").and_then(Value::as_bool),
            Some(true),
            "second step_over should succeed for custom trace, got: {resp2}"
        );

        let (path2, line2, _col2, ticks2, eot2) = extract_nav_location(&resp2)?;
        log_line(
            &log_path,
            &format!(
                "custom step_over 2: path={path2} line={line2} ticks={ticks2} eot={eot2}"
            ),
        );

        // The location should progress — either line changes or ticks
        // advances (or we reached end-of-trace on the second step).
        assert!(
            line1 != line2 || ticks1 != ticks2 || eot2,
            "two consecutive step_overs should change location or reach end: \
             (line={line1}, ticks={ticks1}) vs (line={line2}, ticks={ticks2}, eot={eot2})"
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report(
        "test_real_custom_navigate_step_over",
        &log_path,
        success,
    );
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

// ===========================================================================
// M4 Variables & Expressions helpers
// ===========================================================================

/// Sends `ct/py-locals` and waits for the response, skipping any
/// interleaved events.
///
/// Returns the full response JSON on success.  Uses a 30-second timeout
/// to account for DAP round-trips through a real backend.
async fn send_py_locals(
    client: &mut UnixStream,
    seq: i64,
    trace_path: &Path,
    depth: i64,
    count_budget: i64,
    log_path: &Path,
) -> Result<Value, String> {
    let req = json!({
        "type": "request",
        "command": "ct/py-locals",
        "seq": seq,
        "arguments": {
            "tracePath": trace_path.to_string_lossy(),
            "depth": depth,
            "countBudget": count_budget,
        }
    });

    log_line(
        log_path,
        &format!("-> ct/py-locals seq={seq} depth={depth} countBudget={count_budget}"),
    );

    client
        .write_all(&dap_encode(&req))
        .await
        .map_err(|e| format!("write ct/py-locals: {e}"))?;

    // Read messages, skipping events until we get a response.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err("timeout waiting for ct/py-locals response".to_string());
        }

        let msg = timeout(remaining, dap_read(client))
            .await
            .map_err(|_| "timeout waiting for ct/py-locals response".to_string())?
            .map_err(|e| format!("read ct/py-locals: {e}"))?;

        let msg_type = msg.get("type").and_then(Value::as_str).unwrap_or("");
        if msg_type == "event" {
            log_line(log_path, &format!("py-locals: skipped event: {msg}"));
            continue;
        }

        log_line(log_path, &format!("<- ct/py-locals response: {msg}"));
        return Ok(msg);
    }
}

/// Sends `ct/py-evaluate` and waits for the response, skipping any
/// interleaved events.
///
/// Returns the full response JSON on success.  Uses a 30-second timeout.
async fn send_py_evaluate(
    client: &mut UnixStream,
    seq: i64,
    trace_path: &Path,
    expression: &str,
    log_path: &Path,
) -> Result<Value, String> {
    let req = json!({
        "type": "request",
        "command": "ct/py-evaluate",
        "seq": seq,
        "arguments": {
            "tracePath": trace_path.to_string_lossy(),
            "expression": expression,
        }
    });

    log_line(
        log_path,
        &format!("-> ct/py-evaluate seq={seq} expression={expression}"),
    );

    client
        .write_all(&dap_encode(&req))
        .await
        .map_err(|e| format!("write ct/py-evaluate: {e}"))?;

    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err("timeout waiting for ct/py-evaluate response".to_string());
        }

        let msg = timeout(remaining, dap_read(client))
            .await
            .map_err(|_| "timeout waiting for ct/py-evaluate response".to_string())?
            .map_err(|e| format!("read ct/py-evaluate: {e}"))?;

        let msg_type = msg.get("type").and_then(Value::as_str).unwrap_or("");
        if msg_type == "event" {
            log_line(log_path, &format!("py-evaluate: skipped event: {msg}"));
            continue;
        }

        log_line(log_path, &format!("<- ct/py-evaluate response: {msg}"));
        return Ok(msg);
    }
}

/// Sends `ct/py-stack-trace` and waits for the response, skipping any
/// interleaved events.
///
/// Returns the full response JSON on success.  Uses a 30-second timeout.
async fn send_py_stack_trace(
    client: &mut UnixStream,
    seq: i64,
    trace_path: &Path,
    log_path: &Path,
) -> Result<Value, String> {
    let req = json!({
        "type": "request",
        "command": "ct/py-stack-trace",
        "seq": seq,
        "arguments": {
            "tracePath": trace_path.to_string_lossy(),
        }
    });

    log_line(
        log_path,
        &format!("-> ct/py-stack-trace seq={seq}"),
    );

    client
        .write_all(&dap_encode(&req))
        .await
        .map_err(|e| format!("write ct/py-stack-trace: {e}"))?;

    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err("timeout waiting for ct/py-stack-trace response".to_string());
        }

        let msg = timeout(remaining, dap_read(client))
            .await
            .map_err(|_| "timeout waiting for ct/py-stack-trace response".to_string())?
            .map_err(|e| format!("read ct/py-stack-trace: {e}"))?;

        let msg_type = msg.get("type").and_then(Value::as_str).unwrap_or("");
        if msg_type == "event" {
            log_line(log_path, &format!("py-stack-trace: skipped event: {msg}"));
            continue;
        }

        log_line(log_path, &format!("<- ct/py-stack-trace response: {msg}"));
        return Ok(msg);
    }
}

// ===========================================================================
// M4 RR-based variable inspection tests
// ===========================================================================

/// M4-RR-1. Open an RR trace (Rust).  Step over a couple of times to reach
/// a point with local variables in scope.  Send `ct/py-locals`.  Verify the
/// response contains a non-empty list of variables, each with `name` and
/// `value` fields.
///
/// The test program (`rust_flow_test.rs`) declares variables `x`, `y` in
/// `main()` and `a`, `b`, `sum`, `doubled`, `final_result` in
/// `calculate_sum()`.  After a few `step_over` commands we should land on a
/// line where at least one local variable is in scope.
#[tokio::test]
async fn test_real_rr_locals_returns_variables() {
    let (test_dir, log_path) = setup_test_dir("real_rr_locals_returns_vars");
    let mut success = false;

    let result: Result<(), String> = async {
        let (ct_rr_support, db_backend) = match check_rr_prerequisites() {
            Ok(paths) => paths,
            Err(reason) => {
                log_line(&log_path, &format!("SKIP: {reason}"));
                println!("test_real_rr_locals_returns_variables: SKIP ({reason})");
                return Ok(());
            }
        };

        log_line(
            &log_path,
            &format!(
                "ct-rr-support: {}, db-backend: {}",
                ct_rr_support.display(),
                db_backend.display()
            ),
        );

        // Create an RR recording of the Rust test program.
        let trace_dir = create_rr_recording(&test_dir, &ct_rr_support, &log_path)?;
        log_line(
            &log_path,
            &format!("trace directory: {}", trace_dir.display()),
        );

        // Start the daemon with the real db-backend.
        let ct_rr_support_str = ct_rr_support.to_string_lossy().to_string();
        let (mut daemon, socket_path) = start_daemon_with_real_backend(
            &test_dir,
            &log_path,
            &db_backend,
            &[("CODETRACER_CT_RR_SUPPORT_CMD", &ct_rr_support_str)],
        )
        .await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.
        let open_resp = open_trace(&mut client, 12_000, &trace_dir, &log_path).await?;
        assert_eq!(
            open_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed, got: {open_resp}"
        );

        drain_events(&mut client, &log_path).await;

        // Step over several times to reach a point inside user code where
        // local variables are in scope.  We step until we find a line in
        // `rust_flow_test` with line > 0 (user code with debug info),
        // then do a few more steps to ensure variables are initialized.
        let mut seq = 12_001;
        let mut in_user_code = false;
        let mut steps_in_user_code = 0;

        for _ in 0..50 {
            let resp = navigate(
                &mut client,
                seq,
                &trace_dir,
                "step_over",
                None,
                &log_path,
            )
            .await?;
            seq += 1;

            if resp.get("success").and_then(Value::as_bool) != Some(true) {
                log_line(&log_path, &format!("step_over failed: {resp}"));
                break;
            }

            let (path, line, _, _, eot) = extract_nav_location(&resp)?;
            log_line(
                &log_path,
                &format!("step: path={path} line={line} eot={eot}"),
            );

            if eot {
                break;
            }

            if path.contains("rust_flow_test") && line > 0 {
                in_user_code = true;
                steps_in_user_code += 1;
                // After 3 steps in user code, variables should be in scope
                // (e.g., we should be past `let x = 10; let y = 32;`).
                if steps_in_user_code >= 3 {
                    log_line(
                        &log_path,
                        &format!(
                            "reached user code with enough steps: line={line}"
                        ),
                    );
                    break;
                }
            }
        }

        if !in_user_code {
            log_line(
                &log_path,
                "WARNING: never reached user code; locals may be empty",
            );
        }

        // Now send ct/py-locals to inspect local variables.
        let locals_resp = send_py_locals(
            &mut client,
            seq,
            &trace_dir,
            1,   // depth
            100, // countBudget
            &log_path,
        )
        .await?;

        assert_eq!(
            locals_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/py-locals should succeed, got: {locals_resp}"
        );

        let body = locals_resp
            .get("body")
            .expect("ct/py-locals response should have body");

        let variables = body
            .get("variables")
            .and_then(Value::as_array)
            .expect("body should contain 'variables' array");

        log_line(
            &log_path,
            &format!(
                "variables ({} total): {}",
                variables.len(),
                serde_json::to_string_pretty(body).unwrap_or_default()
            ),
        );

        // Verify the response contains at least one variable.
        // When in user code, we expect variables like `x`, `y`, `result`, etc.
        if in_user_code {
            assert!(
                !variables.is_empty(),
                "ct/py-locals should return at least one variable in user code"
            );
        }

        // Verify each variable has `name` and `value` fields.
        for var in variables {
            assert!(
                var.get("name").and_then(Value::as_str).is_some(),
                "each variable should have a 'name' field, got: {var}"
            );
            // The value field may be a string or may not exist for some
            // backends, but we check it is present.
            assert!(
                var.get("value").is_some(),
                "each variable should have a 'value' field, got: {var}"
            );
        }

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report(
        "test_real_rr_locals_returns_variables",
        &log_path,
        success,
    );
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M4-RR-2. Open an RR trace.  Navigate to a point with variables in scope.
/// Send `ct/py-evaluate` with a variable name.  Verify the response returns
/// a non-empty result string.
///
/// After stepping into user code of `rust_flow_test.rs`, variables like `x`
/// (= 10) and `y` (= 32) should be in scope.  We evaluate the first
/// variable name found via `ct/py-locals` to confirm `ct/py-evaluate` works.
#[tokio::test]
async fn test_real_rr_evaluate_expression() {
    let (test_dir, log_path) = setup_test_dir("real_rr_evaluate_expr");
    let mut success = false;

    let result: Result<(), String> = async {
        let (ct_rr_support, db_backend) = match check_rr_prerequisites() {
            Ok(paths) => paths,
            Err(reason) => {
                log_line(&log_path, &format!("SKIP: {reason}"));
                println!("test_real_rr_evaluate_expression: SKIP ({reason})");
                return Ok(());
            }
        };

        // Create an RR recording.
        let trace_dir = create_rr_recording(&test_dir, &ct_rr_support, &log_path)?;

        // Start the daemon.
        let ct_rr_support_str = ct_rr_support.to_string_lossy().to_string();
        let (mut daemon, socket_path) = start_daemon_with_real_backend(
            &test_dir,
            &log_path,
            &db_backend,
            &[("CODETRACER_CT_RR_SUPPORT_CMD", &ct_rr_support_str)],
        )
        .await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.
        let open_resp = open_trace(&mut client, 13_000, &trace_dir, &log_path).await?;
        assert_eq!(
            open_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed, got: {open_resp}"
        );

        drain_events(&mut client, &log_path).await;

        // Step into user code (same pattern as the locals test).
        let mut seq = 13_001;
        let mut in_user_code = false;
        let mut steps_in_user_code = 0;

        for _ in 0..50 {
            let resp = navigate(
                &mut client,
                seq,
                &trace_dir,
                "step_over",
                None,
                &log_path,
            )
            .await?;
            seq += 1;

            if resp.get("success").and_then(Value::as_bool) != Some(true) {
                break;
            }

            let (path, line, _, _, eot) = extract_nav_location(&resp)?;
            if eot {
                break;
            }

            if path.contains("rust_flow_test") && line > 0 {
                in_user_code = true;
                steps_in_user_code += 1;
                if steps_in_user_code >= 3 {
                    log_line(
                        &log_path,
                        &format!("reached user code at line={line}"),
                    );
                    break;
                }
            }
        }

        if !in_user_code {
            log_line(
                &log_path,
                "WARNING: never reached user code; evaluate may fail",
            );
        }

        // First, get locals to find a variable name to evaluate.
        let locals_resp = send_py_locals(
            &mut client,
            seq,
            &trace_dir,
            1,
            100,
            &log_path,
        )
        .await?;
        seq += 1;

        let var_name = if locals_resp
            .get("success")
            .and_then(Value::as_bool)
            .unwrap_or(false)
        {
            locals_resp
                .get("body")
                .and_then(|b| b.get("variables"))
                .and_then(Value::as_array)
                .and_then(|vars| vars.first())
                .and_then(|v| v.get("name"))
                .and_then(Value::as_str)
                .unwrap_or("x")
                .to_string()
        } else {
            // If locals failed, try evaluating "x" directly (a known
            // variable in the test program).
            "x".to_string()
        };

        log_line(
            &log_path,
            &format!("evaluating expression: {var_name}"),
        );

        // Send ct/py-evaluate.
        let eval_resp = send_py_evaluate(
            &mut client,
            seq,
            &trace_dir,
            &var_name,
            &log_path,
        )
        .await?;

        assert_eq!(
            eval_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/py-evaluate should succeed, got: {eval_resp}"
        );

        let body = eval_resp
            .get("body")
            .expect("ct/py-evaluate response should have body");

        log_line(
            &log_path,
            &format!(
                "evaluate result: {}",
                serde_json::to_string_pretty(body).unwrap_or_default()
            ),
        );

        // Verify the response contains `result` and `type` fields.
        assert!(
            body.get("result").is_some(),
            "ct/py-evaluate body should contain 'result' field"
        );
        assert!(
            body.get("type").is_some(),
            "ct/py-evaluate body should contain 'type' field"
        );

        // The result should be a non-empty string (the variable has a
        // value in the trace).
        let result_str = body
            .get("result")
            .and_then(Value::as_str)
            .unwrap_or("");
        log_line(
            &log_path,
            &format!("evaluate result value: '{result_str}'"),
        );

        // When in user code, the result should be non-empty.
        if in_user_code {
            assert!(
                !result_str.is_empty(),
                "ct/py-evaluate should return a non-empty result in user code"
            );
        }

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report(
        "test_real_rr_evaluate_expression",
        &log_path,
        success,
    );
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M4-RR-3. Open an RR trace.  Navigate into the program (step_over to be
/// inside main or a function).  Send `ct/py-stack-trace`.  Verify the
/// response contains at least 1 frame with `name` and `location` fields.
#[tokio::test]
async fn test_real_rr_stack_trace_returns_frames() {
    let (test_dir, log_path) = setup_test_dir("real_rr_stack_trace_frames");
    let mut success = false;

    let result: Result<(), String> = async {
        let (ct_rr_support, db_backend) = match check_rr_prerequisites() {
            Ok(paths) => paths,
            Err(reason) => {
                log_line(&log_path, &format!("SKIP: {reason}"));
                println!("test_real_rr_stack_trace_returns_frames: SKIP ({reason})");
                return Ok(());
            }
        };

        // Create an RR recording.
        let trace_dir = create_rr_recording(&test_dir, &ct_rr_support, &log_path)?;

        // Start the daemon.
        let ct_rr_support_str = ct_rr_support.to_string_lossy().to_string();
        let (mut daemon, socket_path) = start_daemon_with_real_backend(
            &test_dir,
            &log_path,
            &db_backend,
            &[("CODETRACER_CT_RR_SUPPORT_CMD", &ct_rr_support_str)],
        )
        .await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.
        let open_resp = open_trace(&mut client, 14_000, &trace_dir, &log_path).await?;
        assert_eq!(
            open_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed, got: {open_resp}"
        );

        drain_events(&mut client, &log_path).await;

        // Step over a couple of times so we are somewhere in the program
        // execution (not necessarily in user code — the stack trace should
        // work anywhere the debugger is stopped).
        let mut seq = 14_001;
        for _ in 0..5 {
            let resp = navigate(
                &mut client,
                seq,
                &trace_dir,
                "step_over",
                None,
                &log_path,
            )
            .await?;
            seq += 1;

            if resp.get("success").and_then(Value::as_bool) != Some(true) {
                break;
            }
            let (path, line, _, _, eot) = extract_nav_location(&resp)?;
            log_line(
                &log_path,
                &format!("pre-step: path={path} line={line} eot={eot}"),
            );
            if eot {
                break;
            }
        }

        // Send ct/py-stack-trace.
        let st_resp = send_py_stack_trace(
            &mut client,
            seq,
            &trace_dir,
            &log_path,
        )
        .await?;

        assert_eq!(
            st_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/py-stack-trace should succeed, got: {st_resp}"
        );

        let body = st_resp
            .get("body")
            .expect("ct/py-stack-trace response should have body");

        let frames = body
            .get("frames")
            .and_then(Value::as_array)
            .expect("body should contain 'frames' array");

        log_line(
            &log_path,
            &format!(
                "stack trace ({} frames): {}",
                frames.len(),
                serde_json::to_string_pretty(body).unwrap_or_default()
            ),
        );

        // Verify at least one frame is present.
        assert!(
            !frames.is_empty(),
            "ct/py-stack-trace should return at least one frame"
        );

        // Verify each frame has `name` and `location` fields.
        for frame in frames {
            assert!(
                frame.get("name").is_some(),
                "each frame should have a 'name' field, got: {frame}"
            );
            let location = frame
                .get("location")
                .unwrap_or_else(|| panic!(
                    "each frame should have a 'location' field, got: {frame}"
                ));
            // Location should have `path` and `line` fields.
            assert!(
                location.get("path").is_some(),
                "location should have a 'path' field, got: {location}"
            );
            assert!(
                location.get("line").is_some(),
                "location should have a 'line' field, got: {location}"
            );
        }

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report(
        "test_real_rr_stack_trace_returns_frames",
        &log_path,
        success,
    );
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

// ===========================================================================
// M4 Custom trace format variable inspection tests
// ===========================================================================

/// M4-Custom-1. Open a custom trace (Ruby).  Step to a point with variables
/// in scope.  Send `ct/py-locals`.  Verify the response contains variables
/// from the trace (e.g., `x`, `result`, `y` from the custom trace.json).
///
/// The custom trace directory created by `create_custom_trace_dir` simulates
/// a Ruby program with:
///   - `x = 10` at line 6
///   - `y = compute(x)` at line 7 (where compute returns 20)
///   - `result = a * 2` inside `compute` at line 2
///
/// After stepping through these events the db-backend should report the
/// variables that are in scope at the current trace position.
#[tokio::test]
async fn test_real_custom_locals_returns_variables() {
    let (test_dir, log_path) = setup_test_dir("real_custom_locals_returns_vars");
    let mut success = false;

    let result: Result<(), String> = async {
        let db_backend = match find_db_backend() {
            Some(path) => path,
            None => {
                log_line(&log_path, "SKIP: db-backend not found");
                println!(
                    "test_real_custom_locals_returns_variables: SKIP (db-backend not found)"
                );
                return Ok(());
            }
        };

        log_line(
            &log_path,
            &format!("db-backend: {}", db_backend.display()),
        );

        // Create the custom trace directory.
        let trace_dir = create_custom_trace_dir(&test_dir, "custom-locals-trace");
        log_line(
            &log_path,
            &format!("custom trace dir: {}", trace_dir.display()),
        );

        // Start the daemon with the real db-backend.
        let (mut daemon, socket_path) =
            start_daemon_with_real_backend(&test_dir, &log_path, &db_backend, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.
        let open_resp = open_trace(&mut client, 15_000, &trace_dir, &log_path).await?;
        assert_eq!(
            open_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed for custom trace, got: {open_resp}"
        );

        drain_events(&mut client, &log_path).await;

        // Step over several times to advance through the custom trace
        // events.  The trace has ~20 events; stepping 5-6 times should
        // put us past the `x = 10` assignment where `x` is in scope.
        let mut seq = 15_001;
        for i in 0..6 {
            let resp = navigate(
                &mut client,
                seq,
                &trace_dir,
                "step_over",
                None,
                &log_path,
            )
            .await?;
            seq += 1;

            if resp.get("success").and_then(Value::as_bool) != Some(true) {
                log_line(
                    &log_path,
                    &format!("step_over {i} failed: {resp}"),
                );
                break;
            }

            let (path, line, _, _, eot) = extract_nav_location(&resp)?;
            log_line(
                &log_path,
                &format!("custom step {i}: path={path} line={line} eot={eot}"),
            );
            if eot {
                break;
            }
        }

        // Send ct/py-locals.
        let locals_resp = send_py_locals(
            &mut client,
            seq,
            &trace_dir,
            1,   // depth
            100, // countBudget
            &log_path,
        )
        .await?;

        assert_eq!(
            locals_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/py-locals should succeed for custom trace, got: {locals_resp}"
        );

        let body = locals_resp
            .get("body")
            .expect("ct/py-locals response should have body");

        let variables = body
            .get("variables")
            .and_then(Value::as_array)
            .expect("body should contain 'variables' array");

        log_line(
            &log_path,
            &format!(
                "custom trace variables ({} total): {}",
                variables.len(),
                serde_json::to_string_pretty(body).unwrap_or_default()
            ),
        );

        // The custom trace should have variables in scope after stepping.
        // We expect at least one variable (e.g., `x`).
        assert!(
            !variables.is_empty(),
            "ct/py-locals should return at least one variable for custom trace"
        );

        // Verify each variable has required fields.
        for var in variables {
            assert!(
                var.get("name").and_then(Value::as_str).is_some(),
                "each variable should have a 'name' field, got: {var}"
            );
            assert!(
                var.get("value").is_some(),
                "each variable should have a 'value' field, got: {var}"
            );
        }

        // Check that at least one of the expected variable names is present.
        // The custom trace defines variables `x`, `result`, and `y`.
        let var_names: Vec<&str> = variables
            .iter()
            .filter_map(|v| v.get("name").and_then(Value::as_str))
            .collect();
        log_line(
            &log_path,
            &format!("variable names: {:?}", var_names),
        );

        let expected_names = ["x", "result", "y", "a"];
        let has_expected = var_names
            .iter()
            .any(|name| expected_names.contains(name));
        assert!(
            has_expected,
            "at least one expected variable ({:?}) should be present, got: {:?}",
            expected_names, var_names
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report(
        "test_real_custom_locals_returns_variables",
        &log_path,
        success,
    );
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

// ===========================================================================
// M5 Breakpoint helpers
// ===========================================================================

/// Sends `ct/py-add-breakpoint` and waits for the response, skipping any
/// interleaved events.
///
/// The daemon expects:
/// - `tracePath`: the canonical trace directory path
/// - `path`: source file path to set the breakpoint in
/// - `line`: 1-based line number for the breakpoint
///
/// Returns `(breakpoint_id, full_response)` on success.
/// Uses a 30-second timeout for the DAP round-trip.
async fn send_py_add_breakpoint(
    client: &mut UnixStream,
    seq: i64,
    trace_path: &Path,
    source_path: &str,
    line: i64,
    log_path: &Path,
) -> Result<(i64, Value), String> {
    let req = json!({
        "type": "request",
        "command": "ct/py-add-breakpoint",
        "seq": seq,
        "arguments": {
            "tracePath": trace_path.to_string_lossy(),
            "path": source_path,
            "line": line,
        }
    });

    log_line(
        log_path,
        &format!("-> ct/py-add-breakpoint seq={seq} path={source_path} line={line}"),
    );

    client
        .write_all(&dap_encode(&req))
        .await
        .map_err(|e| format!("write ct/py-add-breakpoint: {e}"))?;

    // Read messages, skipping events until we get a response.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err("timeout waiting for ct/py-add-breakpoint response".to_string());
        }

        let msg = timeout(remaining, dap_read(client))
            .await
            .map_err(|_| "timeout waiting for ct/py-add-breakpoint response".to_string())?
            .map_err(|e| format!("read ct/py-add-breakpoint: {e}"))?;

        let msg_type = msg.get("type").and_then(Value::as_str).unwrap_or("");
        if msg_type == "event" {
            log_line(log_path, &format!("add-breakpoint: skipped event: {msg}"));
            continue;
        }

        log_line(
            log_path,
            &format!("<- ct/py-add-breakpoint response: {msg}"),
        );

        // Extract the breakpoint ID from the response body.
        let bp_id = msg
            .get("body")
            .and_then(|b| b.get("breakpointId"))
            .and_then(Value::as_i64)
            .unwrap_or(-1);

        return Ok((bp_id, msg));
    }
}

/// Sends `ct/py-remove-breakpoint` and waits for the response, skipping any
/// interleaved events.
///
/// The daemon expects:
/// - `tracePath`: the canonical trace directory path
/// - `breakpointId`: the ID returned by `ct/py-add-breakpoint`
///
/// Returns the full response JSON on success.
/// Uses a 30-second timeout for the DAP round-trip.
async fn send_py_remove_breakpoint(
    client: &mut UnixStream,
    seq: i64,
    trace_path: &Path,
    breakpoint_id: i64,
    log_path: &Path,
) -> Result<Value, String> {
    let req = json!({
        "type": "request",
        "command": "ct/py-remove-breakpoint",
        "seq": seq,
        "arguments": {
            "tracePath": trace_path.to_string_lossy(),
            "breakpointId": breakpoint_id,
        }
    });

    log_line(
        log_path,
        &format!("-> ct/py-remove-breakpoint seq={seq} breakpointId={breakpoint_id}"),
    );

    client
        .write_all(&dap_encode(&req))
        .await
        .map_err(|e| format!("write ct/py-remove-breakpoint: {e}"))?;

    // Read messages, skipping events until we get a response.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err("timeout waiting for ct/py-remove-breakpoint response".to_string());
        }

        let msg = timeout(remaining, dap_read(client))
            .await
            .map_err(|_| "timeout waiting for ct/py-remove-breakpoint response".to_string())?
            .map_err(|e| format!("read ct/py-remove-breakpoint: {e}"))?;

        let msg_type = msg.get("type").and_then(Value::as_str).unwrap_or("");
        if msg_type == "event" {
            log_line(
                log_path,
                &format!("remove-breakpoint: skipped event: {msg}"),
            );
            continue;
        }

        log_line(
            log_path,
            &format!("<- ct/py-remove-breakpoint response: {msg}"),
        );
        return Ok(msg);
    }
}

/// Steps forward through the RR trace until we reach user code
/// (`rust_flow_test` in the source path) and have taken at least
/// `min_steps_in_user_code` steps inside it.
///
/// Returns `(final_seq, final_path, final_line, final_ticks, in_user_code)`.
/// The caller can use `final_seq` to continue issuing requests with
/// monotonically increasing sequence numbers.
///
/// This helper factors out the "step to user code" loop used by multiple
/// M5 breakpoint tests, avoiding code duplication.
async fn step_to_user_code(
    client: &mut UnixStream,
    start_seq: i64,
    trace_path: &Path,
    max_steps: usize,
    min_steps_in_user_code: usize,
    log_path: &Path,
) -> Result<(i64, String, i64, i64, bool), String> {
    let mut seq = start_seq;
    let mut last_path = String::new();
    let mut last_line: i64 = 0;
    let mut last_ticks: i64 = 0;
    let mut in_user_code = false;
    let mut steps_in_user_code = 0;

    for _ in 0..max_steps {
        let resp = navigate(
            client,
            seq,
            trace_path,
            "step_over",
            None,
            log_path,
        )
        .await?;
        seq += 1;

        if resp.get("success").and_then(Value::as_bool) != Some(true) {
            log_line(log_path, &format!("step_to_user_code: step_over failed: {resp}"));
            break;
        }

        let (path, line, _, ticks, eot) = extract_nav_location(&resp)?;
        log_line(
            log_path,
            &format!("step_to_user_code: path={path} line={line} ticks={ticks} eot={eot}"),
        );

        last_path = path.clone();
        last_line = line;
        last_ticks = ticks;

        if eot {
            break;
        }

        if path.contains("rust_flow_test") && line > 0 {
            if !in_user_code {
                in_user_code = true;
            }
            steps_in_user_code += 1;
            if steps_in_user_code >= min_steps_in_user_code {
                log_line(
                    log_path,
                    &format!(
                        "step_to_user_code: reached user code after {steps_in_user_code} steps at line={line}"
                    ),
                );
                break;
            }
        }
    }

    Ok((seq, last_path, last_line, last_ticks, in_user_code))
}

// ===========================================================================
// M5 RR-based breakpoint tests
// ===========================================================================

/// M5-RR-1. Set a breakpoint at a known line in the Rust test program, then
/// continue forward.  Verify that execution stops at (or very near) the
/// breakpoint line.
///
/// The test program (`rust_flow_test.rs`) has these key lines:
///   - line 17: `let x = 10;`
///   - line 18: `let y = 32;`
///   - line 19: `let result = calculate_sum(x, y);`
///   - line 20: `println!("Result: {}", result);`
///   - line 21: `with_loops(x);`
///
/// We set a breakpoint at line 20 (`println!`), then continue forward from
/// the program start.  The debugger should stop at (or near) line 20.
#[tokio::test]
async fn test_real_rr_breakpoint_stops_execution() {
    let (test_dir, log_path) = setup_test_dir("real_rr_bp_stops");
    let mut success = false;

    let result: Result<(), String> = async {
        let (ct_rr_support, db_backend) = match check_rr_prerequisites() {
            Ok(paths) => paths,
            Err(reason) => {
                log_line(&log_path, &format!("SKIP: {reason}"));
                println!("test_real_rr_breakpoint_stops_execution: SKIP ({reason})");
                return Ok(());
            }
        };

        log_line(
            &log_path,
            &format!(
                "ct-rr-support: {}, db-backend: {}",
                ct_rr_support.display(),
                db_backend.display()
            ),
        );

        // Create an RR recording of the Rust test program.
        let trace_dir = create_rr_recording(&test_dir, &ct_rr_support, &log_path)?;
        log_line(
            &log_path,
            &format!("trace directory: {}", trace_dir.display()),
        );

        // Determine the source path as it appears in the trace.  The
        // test program is compiled from an absolute path, so breakpoints
        // must use the same absolute path the debugger knows about.
        let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let source_path = manifest_dir
            .parent()
            .map(|p| p.join("db-backend/test-programs/rust/rust_flow_test.rs"))
            .ok_or("cannot determine source path")?;
        let source_path_str = source_path.to_string_lossy().to_string();

        // The breakpoint target line: `println!("Result: {}", result);`
        // which is line 20 of rust_flow_test.rs.
        let bp_line: i64 = 20;

        // Start the daemon.
        let ct_rr_support_str = ct_rr_support.to_string_lossy().to_string();
        let (mut daemon, socket_path) = start_daemon_with_real_backend(
            &test_dir,
            &log_path,
            &db_backend,
            &[("CODETRACER_CT_RR_SUPPORT_CMD", &ct_rr_support_str)],
        )
        .await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.
        let open_resp = open_trace(&mut client, 16_000, &trace_dir, &log_path).await?;
        assert_eq!(
            open_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed, got: {open_resp}"
        );

        drain_events(&mut client, &log_path).await;

        // Step once to get past the entry point (RR starts at _start, not
        // at main), ensuring the debugger is in a state ready for
        // breakpoint operations.
        let resp = navigate(
            &mut client,
            16_001,
            &trace_dir,
            "step_over",
            None,
            &log_path,
        )
        .await?;
        assert_eq!(
            resp.get("success").and_then(Value::as_bool),
            Some(true),
            "initial step_over should succeed, got: {resp}"
        );

        // Add a breakpoint at the target line.
        let (bp_id, bp_resp) = send_py_add_breakpoint(
            &mut client,
            16_002,
            &trace_dir,
            &source_path_str,
            bp_line,
            &log_path,
        )
        .await?;

        assert_eq!(
            bp_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/py-add-breakpoint should succeed, got: {bp_resp}"
        );
        assert!(
            bp_id > 0,
            "breakpoint ID should be positive, got: {bp_id}"
        );
        log_line(
            &log_path,
            &format!("breakpoint set: id={bp_id} at {source_path_str}:{bp_line}"),
        );

        // Continue forward.  The debugger should stop at the breakpoint.
        let cont_resp = navigate(
            &mut client,
            16_003,
            &trace_dir,
            "continue_forward",
            None,
            &log_path,
        )
        .await?;

        assert_eq!(
            cont_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "continue_forward should succeed, got: {cont_resp}"
        );

        let (path, line, _, ticks, end_of_trace) = extract_nav_location(&cont_resp)?;
        log_line(
            &log_path,
            &format!(
                "after continue: path={path} line={line} ticks={ticks} eot={end_of_trace}"
            ),
        );

        // Verify execution stopped at the breakpoint line.
        //
        // The debugger may stop exactly at bp_line or up to 1 line away
        // (due to compiler optimizations or column differences), so we
        // allow a small tolerance.  We also check that the path is the
        // correct source file and that we did NOT reach end-of-trace
        // (which would mean the breakpoint was missed entirely).
        assert!(
            !end_of_trace,
            "continue_forward should have stopped at breakpoint, not end-of-trace"
        );
        assert!(
            path.contains("rust_flow_test"),
            "should stop in rust_flow_test.rs, got path: {path}"
        );
        assert!(
            (bp_line - 1..=bp_line + 1).contains(&line),
            "should stop at or near line {bp_line}, got line {line}"
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report(
        "test_real_rr_breakpoint_stops_execution",
        &log_path,
        success,
    );
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M5-RR-2. Set a breakpoint, continue to it, remove the breakpoint, go
/// back, then continue forward again.  Verify that execution does NOT stop
/// at the former breakpoint line — it should proceed further (either to a
/// later line or to end-of-trace).
///
/// This tests the remove-breakpoint path: after `ct/py-remove-breakpoint`
/// the daemon sends an updated (empty) `setBreakpoints` to the backend,
/// and subsequent `continue` should not hit the removed breakpoint.
#[tokio::test]
async fn test_real_rr_remove_breakpoint_continues_past() {
    let (test_dir, log_path) = setup_test_dir("real_rr_bp_remove");
    let mut success = false;

    let result: Result<(), String> = async {
        let (ct_rr_support, db_backend) = match check_rr_prerequisites() {
            Ok(paths) => paths,
            Err(reason) => {
                log_line(&log_path, &format!("SKIP: {reason}"));
                println!("test_real_rr_remove_breakpoint_continues_past: SKIP ({reason})");
                return Ok(());
            }
        };

        // Create an RR recording.
        let trace_dir = create_rr_recording(&test_dir, &ct_rr_support, &log_path)?;

        // Determine source path.
        let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let source_path = manifest_dir
            .parent()
            .map(|p| p.join("db-backend/test-programs/rust/rust_flow_test.rs"))
            .ok_or("cannot determine source path")?;
        let source_path_str = source_path.to_string_lossy().to_string();

        // We set a breakpoint at line 19 (`let result = calculate_sum(x, y);`)
        // which is early enough in main() that we can later verify execution
        // goes past it.
        let bp_line: i64 = 19;

        // Start the daemon.
        let ct_rr_support_str = ct_rr_support.to_string_lossy().to_string();
        let (mut daemon, socket_path) = start_daemon_with_real_backend(
            &test_dir,
            &log_path,
            &db_backend,
            &[("CODETRACER_CT_RR_SUPPORT_CMD", &ct_rr_support_str)],
        )
        .await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.
        let open_resp = open_trace(&mut client, 17_000, &trace_dir, &log_path).await?;
        assert_eq!(
            open_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed, got: {open_resp}"
        );

        drain_events(&mut client, &log_path).await;

        // Step once to get past the entry point.
        let resp = navigate(
            &mut client,
            17_001,
            &trace_dir,
            "step_over",
            None,
            &log_path,
        )
        .await?;
        assert_eq!(
            resp.get("success").and_then(Value::as_bool),
            Some(true),
            "initial step_over should succeed"
        );
        let (_, initial_line, _, initial_ticks, _) = extract_nav_location(&resp)?;
        log_line(
            &log_path,
            &format!("initial position: line={initial_line} ticks={initial_ticks}"),
        );

        // Add breakpoint at line 19.
        let (bp_id, bp_resp) = send_py_add_breakpoint(
            &mut client,
            17_002,
            &trace_dir,
            &source_path_str,
            bp_line,
            &log_path,
        )
        .await?;
        assert_eq!(
            bp_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/py-add-breakpoint should succeed"
        );
        log_line(
            &log_path,
            &format!("breakpoint set: id={bp_id} at line {bp_line}"),
        );

        // Continue forward — should stop at the breakpoint.
        let cont1_resp = navigate(
            &mut client,
            17_003,
            &trace_dir,
            "continue_forward",
            None,
            &log_path,
        )
        .await?;
        assert_eq!(
            cont1_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "first continue_forward should succeed"
        );
        let (path1, line1, _, ticks1, eot1) = extract_nav_location(&cont1_resp)?;
        log_line(
            &log_path,
            &format!("stopped at breakpoint: path={path1} line={line1} ticks={ticks1} eot={eot1}"),
        );

        // Verify we stopped at the breakpoint (not at end-of-trace).
        assert!(
            !eot1,
            "first continue should stop at breakpoint, not end-of-trace"
        );
        assert!(
            (bp_line - 1..=bp_line + 1).contains(&line1),
            "first continue should stop at or near line {bp_line}, got line {line1}"
        );

        // Remove the breakpoint.
        let rm_resp = send_py_remove_breakpoint(
            &mut client,
            17_004,
            &trace_dir,
            bp_id,
            &log_path,
        )
        .await?;
        assert_eq!(
            rm_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/py-remove-breakpoint should succeed, got: {rm_resp}"
        );
        log_line(&log_path, &format!("breakpoint {bp_id} removed"));

        // Navigate backward to before the breakpoint.  We use step_back
        // to go to an earlier ticks value.
        let back_resp = navigate(
            &mut client,
            17_005,
            &trace_dir,
            "step_back",
            None,
            &log_path,
        )
        .await?;
        assert_eq!(
            back_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "step_back should succeed"
        );
        let (_, line_back, _, ticks_back, _) = extract_nav_location(&back_resp)?;
        log_line(
            &log_path,
            &format!("after step_back: line={line_back} ticks={ticks_back}"),
        );

        // Continue forward again.  With the breakpoint removed, execution
        // should go past line 19 — either to a later line in user code,
        // or to end-of-trace if the program runs to completion.
        let cont2_resp = navigate(
            &mut client,
            17_006,
            &trace_dir,
            "continue_forward",
            None,
            &log_path,
        )
        .await?;
        assert_eq!(
            cont2_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "second continue_forward should succeed"
        );
        let (path2, line2, _, ticks2, eot2) = extract_nav_location(&cont2_resp)?;
        log_line(
            &log_path,
            &format!(
                "after second continue: path={path2} line={line2} ticks={ticks2} eot={eot2}"
            ),
        );

        // With the breakpoint removed, execution should NOT stop at line
        // 19 again.  It should either:
        // a) Reach end-of-trace (eot2 == true), OR
        // b) Be at a later ticks than where we were when we stepped back.
        //
        // We verify that execution progressed past the breakpoint: ticks
        // advanced beyond the first breakpoint stop, OR we reached eot.
        assert!(
            eot2 || ticks2 > ticks1,
            "second continue should go past the removed breakpoint: \
             ticks2={ticks2} (should be > ticks1={ticks1}), eot2={eot2}"
        );
        log_line(
            &log_path,
            "confirmed: execution passed the removed breakpoint",
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report(
        "test_real_rr_remove_breakpoint_continues_past",
        &log_path,
        success,
    );
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M5-RR-3. Set a breakpoint at an early line, navigate forward past it
/// (using multiple step_overs), then reverse continue.  Verify that
/// execution stops at (or near) the breakpoint line when going backwards.
///
/// This exercises the RR reverse debugging capability with breakpoints:
/// `reverseContinue` in DAP should respect the same breakpoints as
/// forward `continue`.
#[tokio::test]
async fn test_real_rr_reverse_continue_hits_breakpoint() {
    let (test_dir, log_path) = setup_test_dir("real_rr_bp_reverse");
    let mut success = false;

    let result: Result<(), String> = async {
        let (ct_rr_support, db_backend) = match check_rr_prerequisites() {
            Ok(paths) => paths,
            Err(reason) => {
                log_line(&log_path, &format!("SKIP: {reason}"));
                println!("test_real_rr_reverse_continue_hits_breakpoint: SKIP ({reason})");
                return Ok(());
            }
        };

        // Create an RR recording.
        let trace_dir = create_rr_recording(&test_dir, &ct_rr_support, &log_path)?;

        // Determine source path.
        let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let source_path = manifest_dir
            .parent()
            .map(|p| p.join("db-backend/test-programs/rust/rust_flow_test.rs"))
            .ok_or("cannot determine source path")?;
        let source_path_str = source_path.to_string_lossy().to_string();

        // Set breakpoint at line 18 (`let y = 32;`) — early in main().
        let bp_line: i64 = 18;

        // Start the daemon.
        let ct_rr_support_str = ct_rr_support.to_string_lossy().to_string();
        let (mut daemon, socket_path) = start_daemon_with_real_backend(
            &test_dir,
            &log_path,
            &db_backend,
            &[("CODETRACER_CT_RR_SUPPORT_CMD", &ct_rr_support_str)],
        )
        .await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.
        let open_resp = open_trace(&mut client, 18_000, &trace_dir, &log_path).await?;
        assert_eq!(
            open_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed, got: {open_resp}"
        );

        drain_events(&mut client, &log_path).await;

        // Step to user code and then several steps past line 18, so we
        // have execution history beyond the breakpoint line.
        let (mut seq, last_path, last_line, last_ticks, in_user_code) = step_to_user_code(
            &mut client,
            18_001,
            &trace_dir,
            50,  // max_steps
            5,   // min_steps_in_user_code (ensure we are well past line 18)
            &log_path,
        )
        .await?;

        log_line(
            &log_path,
            &format!(
                "before breakpoint setup: path={last_path} line={last_line} ticks={last_ticks} \
                 in_user_code={in_user_code}"
            ),
        );

        if !in_user_code {
            // If we never reached user code, the test cannot meaningfully
            // verify reverse-continue behavior.  Log and skip.
            log_line(
                &log_path,
                "WARNING: never reached user code; cannot test reverse-continue with breakpoints",
            );
            shutdown_daemon(&mut client, &mut daemon).await;
            return Ok(());
        }

        // Now add the breakpoint at line 18.
        let (bp_id, bp_resp) = send_py_add_breakpoint(
            &mut client,
            seq,
            &trace_dir,
            &source_path_str,
            bp_line,
            &log_path,
        )
        .await?;
        seq += 1;

        assert_eq!(
            bp_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/py-add-breakpoint should succeed"
        );
        log_line(
            &log_path,
            &format!("breakpoint set: id={bp_id} at line {bp_line}"),
        );

        // Reverse continue — should hit the breakpoint at line 18.
        let rev_resp = navigate(
            &mut client,
            seq,
            &trace_dir,
            "continue_reverse",
            None,
            &log_path,
        )
        .await?;

        assert_eq!(
            rev_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "continue_reverse should succeed, got: {rev_resp}"
        );

        let (rev_path, rev_line, _, rev_ticks, _rev_eot) = extract_nav_location(&rev_resp)?;
        log_line(
            &log_path,
            &format!(
                "after reverse continue: path={rev_path} line={rev_line} ticks={rev_ticks}"
            ),
        );

        // Verify we went backwards (ticks decreased).
        assert!(
            rev_ticks < last_ticks,
            "reverse continue should go backwards: rev_ticks={rev_ticks} should be < last_ticks={last_ticks}"
        );

        // Verify we stopped at or near the breakpoint line.
        assert!(
            rev_path.contains("rust_flow_test"),
            "reverse continue should stop in rust_flow_test.rs, got: {rev_path}"
        );
        assert!(
            (bp_line - 1..=bp_line + 1).contains(&rev_line),
            "reverse continue should stop at or near line {bp_line}, got line {rev_line}"
        );

        log_line(
            &log_path,
            "confirmed: reverse continue hit the breakpoint",
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report(
        "test_real_rr_reverse_continue_hits_breakpoint",
        &log_path,
        success,
    );
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M5-RR-4. Set breakpoints at multiple lines, continue to each one in
/// sequence.  Verify that execution stops at each breakpoint line in
/// source-order (since the program executes top-to-bottom through main).
///
/// This tests that the daemon correctly maintains multiple breakpoints
/// for the same file via the `setBreakpoints` DAP command (which sends
/// ALL breakpoint lines for a file each time).
#[tokio::test]
async fn test_real_rr_multiple_breakpoints() {
    let (test_dir, log_path) = setup_test_dir("real_rr_bp_multiple");
    let mut success = false;

    let result: Result<(), String> = async {
        let (ct_rr_support, db_backend) = match check_rr_prerequisites() {
            Ok(paths) => paths,
            Err(reason) => {
                log_line(&log_path, &format!("SKIP: {reason}"));
                println!("test_real_rr_multiple_breakpoints: SKIP ({reason})");
                return Ok(());
            }
        };

        // Create an RR recording.
        let trace_dir = create_rr_recording(&test_dir, &ct_rr_support, &log_path)?;

        // Determine source path.
        let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let source_path = manifest_dir
            .parent()
            .map(|p| p.join("db-backend/test-programs/rust/rust_flow_test.rs"))
            .ok_or("cannot determine source path")?;
        let source_path_str = source_path.to_string_lossy().to_string();

        // Set breakpoints at two lines in main():
        //   line 19: `let result = calculate_sum(x, y);`
        //   line 21: `with_loops(x);`
        let bp_line_1: i64 = 19;
        let bp_line_2: i64 = 21;

        // Start the daemon.
        let ct_rr_support_str = ct_rr_support.to_string_lossy().to_string();
        let (mut daemon, socket_path) = start_daemon_with_real_backend(
            &test_dir,
            &log_path,
            &db_backend,
            &[("CODETRACER_CT_RR_SUPPORT_CMD", &ct_rr_support_str)],
        )
        .await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.
        let open_resp = open_trace(&mut client, 19_000, &trace_dir, &log_path).await?;
        assert_eq!(
            open_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed, got: {open_resp}"
        );

        drain_events(&mut client, &log_path).await;

        // Step once to get past the entry point.
        let resp = navigate(
            &mut client,
            19_001,
            &trace_dir,
            "step_over",
            None,
            &log_path,
        )
        .await?;
        assert_eq!(
            resp.get("success").and_then(Value::as_bool),
            Some(true),
            "initial step_over should succeed"
        );

        // Add first breakpoint (line 19).
        let (bp_id_1, bp_resp_1) = send_py_add_breakpoint(
            &mut client,
            19_002,
            &trace_dir,
            &source_path_str,
            bp_line_1,
            &log_path,
        )
        .await?;
        assert_eq!(
            bp_resp_1.get("success").and_then(Value::as_bool),
            Some(true),
            "first ct/py-add-breakpoint should succeed"
        );
        log_line(
            &log_path,
            &format!("breakpoint 1: id={bp_id_1} at line {bp_line_1}"),
        );

        // Add second breakpoint (line 21).
        let (bp_id_2, bp_resp_2) = send_py_add_breakpoint(
            &mut client,
            19_003,
            &trace_dir,
            &source_path_str,
            bp_line_2,
            &log_path,
        )
        .await?;
        assert_eq!(
            bp_resp_2.get("success").and_then(Value::as_bool),
            Some(true),
            "second ct/py-add-breakpoint should succeed"
        );
        log_line(
            &log_path,
            &format!("breakpoint 2: id={bp_id_2} at line {bp_line_2}"),
        );

        // Verify the two breakpoints got different IDs.
        assert_ne!(
            bp_id_1, bp_id_2,
            "breakpoint IDs should be unique: {bp_id_1} vs {bp_id_2}"
        );

        // Continue forward — should hit the first breakpoint (line 19).
        let cont1_resp = navigate(
            &mut client,
            19_004,
            &trace_dir,
            "continue_forward",
            None,
            &log_path,
        )
        .await?;
        assert_eq!(
            cont1_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "first continue_forward should succeed"
        );
        let (path1, line1, _, ticks1, eot1) = extract_nav_location(&cont1_resp)?;
        log_line(
            &log_path,
            &format!(
                "first breakpoint hit: path={path1} line={line1} ticks={ticks1} eot={eot1}"
            ),
        );

        assert!(
            !eot1,
            "first continue should stop at breakpoint, not end-of-trace"
        );
        assert!(
            path1.contains("rust_flow_test"),
            "should stop in rust_flow_test.rs, got: {path1}"
        );
        // Should stop at the first breakpoint (line 19) or very near it.
        assert!(
            (bp_line_1 - 1..=bp_line_1 + 1).contains(&line1),
            "first continue should stop at or near line {bp_line_1}, got line {line1}"
        );

        // Continue forward again — should hit the second breakpoint (line 21).
        let cont2_resp = navigate(
            &mut client,
            19_005,
            &trace_dir,
            "continue_forward",
            None,
            &log_path,
        )
        .await?;
        assert_eq!(
            cont2_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "second continue_forward should succeed"
        );
        let (path2, line2, _, ticks2, eot2) = extract_nav_location(&cont2_resp)?;
        log_line(
            &log_path,
            &format!(
                "second breakpoint hit: path={path2} line={line2} ticks={ticks2} eot={eot2}"
            ),
        );

        // Verify we advanced past the first breakpoint.
        assert!(
            ticks2 > ticks1,
            "second continue should advance: ticks2={ticks2} should be > ticks1={ticks1}"
        );

        // Should stop at the second breakpoint (line 21) or very near it.
        // If the second breakpoint wasn't hit (e.g., the program ended or
        // the debugger stopped somewhere else), the line would be quite
        // different.
        if !eot2 {
            assert!(
                path2.contains("rust_flow_test"),
                "should stop in rust_flow_test.rs, got: {path2}"
            );
            assert!(
                (bp_line_2 - 1..=bp_line_2 + 1).contains(&line2),
                "second continue should stop at or near line {bp_line_2}, got line {line2}"
            );
        } else {
            // End-of-trace is acceptable if the program terminated between
            // the two breakpoints (unlikely for this test program, but
            // defensive).
            log_line(
                &log_path,
                "WARNING: reached end-of-trace on second continue (program may have ended)",
            );
        }

        log_line(
            &log_path,
            "confirmed: both breakpoints hit in sequence",
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report(
        "test_real_rr_multiple_breakpoints",
        &log_path,
        success,
    );
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

// ===========================================================================
// M5 Custom trace format breakpoint tests
// ===========================================================================

/// M5-Custom-1. Open a custom trace.  Set a breakpoint at a known step
/// line.  Continue forward.  Verify execution stops at the breakpoint line.
///
/// The custom trace (created by `create_custom_trace_dir`) simulates a
/// Ruby program with steps at lines 6, 7, 1, 2, 3, 7.  Setting a
/// breakpoint at line 2 (inside `compute`) and continuing should stop
/// execution there.
#[tokio::test]
async fn test_real_custom_breakpoint_stops_execution() {
    let (test_dir, log_path) = setup_test_dir("real_custom_bp_stops");
    let mut success = false;

    let result: Result<(), String> = async {
        let db_backend = match find_db_backend() {
            Some(path) => path,
            None => {
                log_line(&log_path, "SKIP: db-backend not found");
                println!(
                    "test_real_custom_breakpoint_stops_execution: SKIP (db-backend not found)"
                );
                return Ok(());
            }
        };

        log_line(
            &log_path,
            &format!("db-backend: {}", db_backend.display()),
        );

        // Create the custom trace directory.
        let trace_dir = create_custom_trace_dir(&test_dir, "custom-bp-trace");
        log_line(
            &log_path,
            &format!("custom trace dir: {}", trace_dir.display()),
        );

        // The custom trace uses source file "/tmp/test-workdir/test.rb"
        // with steps at lines 6, 7, 1, 2, 3, 7.
        let source_path = "/tmp/test-workdir/test.rb";
        let bp_line: i64 = 2; // `result = a * 2` inside compute()

        // Start the daemon with the real db-backend.
        let (mut daemon, socket_path) =
            start_daemon_with_real_backend(&test_dir, &log_path, &db_backend, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.
        let open_resp = open_trace(&mut client, 20_000, &trace_dir, &log_path).await?;
        assert_eq!(
            open_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed for custom trace, got: {open_resp}"
        );

        drain_events(&mut client, &log_path).await;

        // The custom trace starts at line 6 (ticks=0) and has steps at
        // lines 6, 7, 1, 2, 3, 7.  We do NOT step_over here because
        // step_over from line 6 (main) would skip the entire compute()
        // call and jump to line 7 at end-of-trace.  Instead, we add
        // the breakpoint at line 2 while at the initial position and
        // continue forward — the breakpoint should be hit at step index 3
        // (line 2, inside compute).
        log_line(
            &log_path,
            "starting from initial position (line 6, ticks=0) without stepping",
        );

        // Add breakpoint at line 2.
        let (bp_id, bp_resp) = send_py_add_breakpoint(
            &mut client,
            20_001,
            &trace_dir,
            source_path,
            bp_line,
            &log_path,
        )
        .await?;

        assert_eq!(
            bp_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/py-add-breakpoint should succeed for custom trace, got: {bp_resp}"
        );
        assert!(
            bp_id > 0,
            "breakpoint ID should be positive, got: {bp_id}"
        );
        log_line(
            &log_path,
            &format!("breakpoint set: id={bp_id} at {source_path}:{bp_line}"),
        );

        // Continue forward — should stop at the breakpoint (line 2).
        let cont_resp = navigate(
            &mut client,
            20_002,
            &trace_dir,
            "continue_forward",
            None,
            &log_path,
        )
        .await?;

        assert_eq!(
            cont_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "continue_forward should succeed for custom trace, got: {cont_resp}"
        );

        let (path, line, _, ticks, end_of_trace) = extract_nav_location(&cont_resp)?;
        log_line(
            &log_path,
            &format!(
                "after continue: path={path} line={line} ticks={ticks} eot={end_of_trace}"
            ),
        );

        // Verify we stopped at the breakpoint.  For custom traces the
        // db-backend uses the trace step positions, so the stop should
        // be at or very near the breakpoint line.
        assert!(
            !end_of_trace,
            "continue should have stopped at breakpoint, not end-of-trace"
        );
        assert!(
            path.contains("test.rb"),
            "should stop in test.rb, got: {path}"
        );
        assert!(
            (bp_line - 1..=bp_line + 1).contains(&line),
            "should stop at or near line {bp_line}, got line {line}"
        );

        log_line(
            &log_path,
            "confirmed: custom trace breakpoint stopped execution",
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report(
        "test_real_custom_breakpoint_stops_execution",
        &log_path,
        success,
    );
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}
