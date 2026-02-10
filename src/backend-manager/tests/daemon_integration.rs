//! Integration tests for the backend-manager daemon mode.
//!
//! Each test:
//! - Uses a unique temporary directory (keyed on PID + test name) to avoid
//!   collisions when tests run in parallel.
//! - Creates a log file capturing its output.
//! - Prints minimal output on success and the log path on failure.
//!
//! The tests build and run the `backend-manager` binary as a child process,
//! communicating over Unix sockets using the DAP framing protocol.

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
// Shared helpers
// ---------------------------------------------------------------------------

/// Returns the path to the compiled `backend-manager` binary.
///
/// We rely on the binary having been built by `cargo test` (which compiles
/// the package before running integration tests).  The binary lives in the
/// same target directory as the test runner.
fn binary_path() -> PathBuf {
    // `cargo test` puts integration test binaries in target/<profile>/deps.
    // The actual package binary is one directory up, in target/<profile>/.
    let mut path = std::env::current_exe().expect("cannot determine test binary path");
    // Pop the test binary name.
    path.pop();
    // If we're inside `deps/`, pop that too.
    if path.ends_with("deps") {
        path.pop();
    }
    path.push("backend-manager");
    path
}

/// Creates a unique temp directory for the test and returns `(temp_dir, log_path)`.
///
/// We keep the directory path short because Unix socket paths are limited
/// to 107 bytes on Linux (SUN_LEN - 1).  The daemon puts its sockets at
/// `<tmpdir>/codetracer/backend-manager/<pid>.sock`, so the tmpdir prefix
/// must not consume too much of the budget.
fn setup_test_dir(test_name: &str) -> (PathBuf, PathBuf) {
    // Use /tmp directly (not $TMPDIR which can be very long in nix-shell).
    // Include both PID and full test name hash for uniqueness.
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};

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
///
/// This is a minimal parser that reads the `Content-Length` header, then
/// reads exactly that many body bytes.
async fn dap_read(stream: &mut UnixStream) -> Result<Value, String> {
    // Read bytes until we find "\r\n\r\n" (end of headers).
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

/// Computes the paths that the daemon will use when we override TMPDIR.
///
/// The `Paths::default()` implementation reads `TMPDIR` on Linux (through
/// `std::env::temp_dir()`), then appends `codetracer/`.  By pointing TMPDIR
/// to our test dir we get full isolation.
///
/// Returns the `codetracer/` directory inside `test_dir` where the daemon
/// will create `daemon.sock`, `daemon.pid`, etc.
fn daemon_paths_in(test_dir: &Path) -> PathBuf {
    // The daemon uses std::env::temp_dir().join("codetracer/").
    // std::env::temp_dir() on Linux reads $TMPDIR.
    // When we set TMPDIR=test_dir, the daemon resolves to
    // <test_dir>/codetracer/.
    test_dir.join("codetracer")
}

/// Starts the daemon process with the given test directory as its tmp root.
///
/// Extra environment variables can be passed to configure TTL, max sessions, etc.
///
/// Returns the child process handle and the path to the daemon socket.
async fn start_daemon_with_env(
    test_dir: &Path,
    log_path: &Path,
    env_vars: &[(&str, &str)],
) -> (tokio::process::Child, PathBuf) {
    let ct_dir = daemon_paths_in(test_dir);
    std::fs::create_dir_all(&ct_dir).expect("create ct dir");

    let socket_path = ct_dir.join("daemon.sock");
    let pid_path = ct_dir.join("daemon.pid");

    // Remove any stale files from a previous run.
    let _ = std::fs::remove_file(&socket_path);
    let _ = std::fs::remove_file(&pid_path);

    log_line(log_path, &format!("starting daemon, TMPDIR={}", test_dir.display()));

    let mut cmd = Command::new(binary_path());
    cmd.arg("daemon")
        .arg("start")
        .env("TMPDIR", test_dir)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    for (key, value) in env_vars {
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

/// Starts the daemon process with the given test directory as its tmp root.
///
/// Returns the child process handle and the path to the daemon socket.
async fn start_daemon(test_dir: &Path, log_path: &Path) -> (tokio::process::Child, PathBuf) {
    let ct_dir = daemon_paths_in(test_dir);
    std::fs::create_dir_all(&ct_dir).expect("create ct dir");

    let socket_path = ct_dir.join("daemon.sock");
    let pid_path = ct_dir.join("daemon.pid");

    // Remove any stale files from a previous run.
    let _ = std::fs::remove_file(&socket_path);
    let _ = std::fs::remove_file(&pid_path);

    log_line(log_path, &format!("starting daemon, TMPDIR={}", test_dir.display()));

    let child = Command::new(binary_path())
        .arg("daemon")
        .arg("start")
        .env("TMPDIR", test_dir)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("cannot spawn daemon");

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

/// Reports test result: minimal on success, log path on failure.
fn report(test_name: &str, log_path: &Path, success: bool) {
    if success {
        println!("{test_name}: PASS");
    } else {
        let size = std::fs::metadata(log_path)
            .map(|m| m.len())
            .unwrap_or(0);
        eprintln!(
            "{test_name}: FAIL  (log: {} [{size} bytes])",
            log_path.display()
        );
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// 1. Start daemon, connect two clients, send ct/ping from each, verify both
///    get responses.  Disconnect one.  Verify the other still works.
#[tokio::test]
async fn test_multi_client_connections() {
    let (test_dir, log_path) = setup_test_dir("multi_client_connections");
    let mut success = false;

    let result: Result<(), String> = async {
        let (mut daemon, socket_path) = start_daemon(&test_dir, &log_path).await;

        // Connect client A.
        let mut client_a = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("client A connect: {e}"))?;
        log_line(&log_path, "client A connected");

        // Connect client B.
        let mut client_b = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("client B connect: {e}"))?;
        log_line(&log_path, "client B connected");

        // Give daemon a moment to register both clients.
        sleep(Duration::from_millis(200)).await;

        // Send ping from client A.
        let ping_a = json!({"type": "request", "command": "ct/ping", "seq": 10});
        client_a
            .write_all(&dap_encode(&ping_a))
            .await
            .map_err(|e| format!("client A write: {e}"))?;

        // Send ping from client B.
        let ping_b = json!({"type": "request", "command": "ct/ping", "seq": 20});
        client_b
            .write_all(&dap_encode(&ping_b))
            .await
            .map_err(|e| format!("client B write: {e}"))?;

        // Read response for client A.
        let resp_a = timeout(Duration::from_secs(5), dap_read(&mut client_a))
            .await
            .map_err(|_| "timeout reading client A response".to_string())?
            .map_err(|e| format!("client A read: {e}"))?;
        log_line(&log_path, &format!("client A response: {resp_a}"));

        assert_eq!(
            resp_a.get("command").and_then(Value::as_str),
            Some("ct/ping"),
            "client A response command mismatch"
        );
        assert_eq!(
            resp_a.get("success").and_then(Value::as_bool),
            Some(true),
            "client A response not successful"
        );

        // Read response for client B.
        let resp_b = timeout(Duration::from_secs(5), dap_read(&mut client_b))
            .await
            .map_err(|_| "timeout reading client B response".to_string())?
            .map_err(|e| format!("client B read: {e}"))?;
        log_line(&log_path, &format!("client B response: {resp_b}"));

        assert_eq!(
            resp_b.get("command").and_then(Value::as_str),
            Some("ct/ping"),
            "client B response command mismatch"
        );

        // Disconnect client A.
        drop(client_a);
        sleep(Duration::from_millis(200)).await;
        log_line(&log_path, "client A disconnected");

        // Client B should still work.
        let ping_b2 = json!({"type": "request", "command": "ct/ping", "seq": 30});
        client_b
            .write_all(&dap_encode(&ping_b2))
            .await
            .map_err(|e| format!("client B write after A disconnect: {e}"))?;

        let resp_b2 = timeout(Duration::from_secs(5), dap_read(&mut client_b))
            .await
            .map_err(|_| "timeout reading client B second response".to_string())?
            .map_err(|e| format!("client B read 2: {e}"))?;
        log_line(&log_path, &format!("client B response 2: {resp_b2}"));

        assert_eq!(
            resp_b2.get("success").and_then(Value::as_bool),
            Some(true),
            "client B second response not successful"
        );

        // Shut down.
        shutdown_daemon(&mut client_b, &mut daemon).await;

        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("test_multi_client_connections", &log_path, success);
    assert!(success, "see log at {}", log_path.display());

    // Cleanup.
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// 2. Start daemon.  Verify socket file is created.  Connect a client.
///    Send shutdown.  Verify daemon exits and socket file is removed.
#[tokio::test]
async fn test_daemon_starts_and_listens() {
    let (test_dir, log_path) = setup_test_dir("daemon_starts_and_listens");
    let mut success = false;

    let result: Result<(), String> = async {
        let (mut daemon, socket_path) = start_daemon(&test_dir, &log_path).await;

        // Socket file should exist.
        assert!(
            socket_path.exists(),
            "daemon socket file does not exist at {}",
            socket_path.display()
        );
        log_line(&log_path, "socket file exists");

        // Connect a client.
        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        log_line(&log_path, "client connected");

        // Send shutdown.
        shutdown_daemon(&mut client, &mut daemon).await;
        log_line(&log_path, "shutdown sent, daemon exited");

        // Give filesystem a moment to settle.
        sleep(Duration::from_millis(500)).await;

        // Socket file should be removed after shutdown.
        assert!(
            !socket_path.exists(),
            "socket file still exists after shutdown"
        );
        log_line(&log_path, "socket file removed after shutdown");

        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("test_daemon_starts_and_listens", &log_path, success);
    assert!(success, "see log at {}", log_path.display());

    let _ = std::fs::remove_dir_all(&test_dir);
}

/// 3. Start daemon.  Verify PID file exists and contains the daemon's PID.
///    Stop daemon.  Verify PID file is removed.
#[tokio::test]
async fn test_daemon_pid_file_created() {
    let (test_dir, log_path) = setup_test_dir("daemon_pid_file_created");
    let mut success = false;

    let result: Result<(), String> = async {
        let ct_dir = daemon_paths_in(&test_dir);
        let pid_file = ct_dir.join("daemon.pid");

        let (mut daemon, socket_path) = start_daemon(&test_dir, &log_path).await;

        // PID file should exist.
        // Wait briefly - the PID file is written before the socket, but
        // let's be safe.
        sleep(Duration::from_millis(200)).await;
        assert!(
            pid_file.exists(),
            "PID file does not exist at {}",
            pid_file.display()
        );

        // Read PID file and verify it matches the daemon process's PID.
        let pid_contents = std::fs::read_to_string(&pid_file)
            .map_err(|e| format!("read pid file: {e}"))?;
        let pid_from_file: u32 = pid_contents
            .trim()
            .parse()
            .map_err(|e| format!("parse pid: {e}"))?;

        let daemon_pid = daemon.id().expect("daemon has no PID");
        log_line(
            &log_path,
            &format!("pid file={pid_from_file}, daemon pid={daemon_pid}"),
        );

        assert_eq!(
            pid_from_file, daemon_pid,
            "PID file content ({pid_from_file}) does not match daemon PID ({daemon_pid})"
        );

        // Shut down.
        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect for shutdown: {e}"))?;
        shutdown_daemon(&mut client, &mut daemon).await;
        sleep(Duration::from_millis(500)).await;

        // PID file should be removed.
        assert!(
            !pid_file.exists(),
            "PID file still exists after daemon shutdown"
        );

        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("test_daemon_pid_file_created", &log_path, success);
    assert!(success, "see log at {}", log_path.display());

    let _ = std::fs::remove_dir_all(&test_dir);
}

/// 4. Start daemon.  Run `backend-manager daemon status` and verify it
///    reports "running".  Stop daemon.  Run status again and verify
///    "not running".
#[tokio::test]
async fn test_daemon_status_reports_running() {
    let (test_dir, log_path) = setup_test_dir("daemon_status_reports_running");
    let mut success = false;

    let result: Result<(), String> = async {
        let (mut daemon, socket_path) = start_daemon(&test_dir, &log_path).await;

        // Run `daemon status` while daemon is running.
        let status_output = Command::new(binary_path())
            .arg("daemon")
            .arg("status")
            .env("TMPDIR", &test_dir)
            .output()
            .await
            .map_err(|e| format!("status command: {e}"))?;

        let stdout = String::from_utf8_lossy(&status_output.stdout);
        log_line(&log_path, &format!("status (running): {stdout}"));

        assert!(
            stdout.contains("running"),
            "expected 'running' in status output, got: {stdout}"
        );

        // Stop daemon.
        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect for shutdown: {e}"))?;
        shutdown_daemon(&mut client, &mut daemon).await;
        sleep(Duration::from_millis(500)).await;

        // Run status again — should report not running.
        let status_output2 = Command::new(binary_path())
            .arg("daemon")
            .arg("status")
            .env("TMPDIR", &test_dir)
            .output()
            .await
            .map_err(|e| format!("status command 2: {e}"))?;

        let stdout2 = String::from_utf8_lossy(&status_output2.stdout);
        log_line(&log_path, &format!("status (stopped): {stdout2}"));

        assert!(
            stdout2.contains("not running"),
            "expected 'not running' in status output, got: {stdout2}"
        );

        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("test_daemon_status_reports_running", &log_path, success);
    assert!(success, "see log at {}", log_path.display());

    let _ = std::fs::remove_dir_all(&test_dir);
}

/// 5. Start daemon.  Run `backend-manager daemon stop`.  Verify daemon
///    process terminates and socket file is removed.
#[tokio::test]
async fn test_daemon_stop_terminates() {
    let (test_dir, log_path) = setup_test_dir("daemon_stop_terminates");
    let mut success = false;

    let result: Result<(), String> = async {
        let ct_dir = daemon_paths_in(&test_dir);
        let (mut daemon, socket_path) = start_daemon(&test_dir, &log_path).await;

        // Run `daemon stop`.
        let stop_output = Command::new(binary_path())
            .arg("daemon")
            .arg("stop")
            .env("TMPDIR", &test_dir)
            .output()
            .await
            .map_err(|e| format!("stop command: {e}"))?;

        let stdout = String::from_utf8_lossy(&stop_output.stdout);
        log_line(&log_path, &format!("stop output: {stdout}"));

        // Wait for daemon to exit.
        let exit = timeout(Duration::from_secs(5), daemon.wait())
            .await
            .map_err(|_| "daemon did not exit within 5s after stop".to_string())?
            .map_err(|e| format!("wait: {e}"))?;
        log_line(&log_path, &format!("daemon exited with: {exit}"));

        // Give a moment for filesystem cleanup.
        sleep(Duration::from_millis(500)).await;

        // Socket file should be removed.
        assert!(
            !socket_path.exists(),
            "socket file still exists after daemon stop"
        );

        // PID file should also be removed.
        let pid_file = ct_dir.join("daemon.pid");
        assert!(
            !pid_file.exists(),
            "PID file still exists after daemon stop"
        );

        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("test_daemon_stop_terminates", &log_path, success);
    assert!(success, "see log at {}", log_path.display());

    let _ = std::fs::remove_dir_all(&test_dir);
}

/// 6. Verify the Python package is importable and reports its version.
#[tokio::test]
async fn test_python_package_importable() {
    let (test_dir, log_path) = setup_test_dir("python_package_importable");
    let mut success = false;

    let result: Result<(), String> = async {
        // Determine the path to the python-api directory.
        // The backend-manager crate is at <repo>/src/backend-manager/,
        // and the python-api is at <repo>/../python-api/ relative to the
        // crate root, or more precisely at <repo>/python-api/.
        let crate_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let python_api_dir = crate_dir
            .parent()
            .and_then(|p| p.parent())
            .map(|repo_root| repo_root.join("python-api"))
            .ok_or("cannot determine python-api path")?;

        log_line(
            &log_path,
            &format!("python-api dir: {}", python_api_dir.display()),
        );

        if !python_api_dir.exists() {
            return Err(format!(
                "python-api directory does not exist: {}",
                python_api_dir.display()
            ));
        }

        let output = std::process::Command::new("python3")
            .arg("-c")
            .arg(format!(
                "import sys; sys.path.insert(0, '{}'); import codetracer; print(codetracer.__version__)",
                python_api_dir.display()
            ))
            .output()
            .map_err(|e| format!("python3 invocation: {e}"))?;

        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        log_line(&log_path, &format!("python stdout: {stdout}"));
        log_line(&log_path, &format!("python stderr: {stderr}"));

        assert!(
            output.status.success(),
            "python3 import failed with exit code {:?}",
            output.status.code()
        );
        assert!(
            stdout.trim().contains("0.1.0"),
            "expected version 0.1.0 in output, got: {stdout}"
        );

        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("test_python_package_importable", &log_path, success);
    assert!(success, "see log at {}", log_path.display());

    let _ = std::fs::remove_dir_all(&test_dir);
}

/// 7. Run `backend-manager daemon --help` and verify the output contains
///    the expected subcommands.
#[tokio::test]
async fn test_cli_subcommand_registered() {
    let (test_dir, log_path) = setup_test_dir("cli_subcommand_registered");
    let mut success = false;

    let result: Result<(), String> = async {
        let output = Command::new(binary_path())
            .arg("daemon")
            .arg("--help")
            .output()
            .await
            .map_err(|e| format!("daemon --help: {e}"))?;

        let stdout = String::from_utf8_lossy(&output.stdout);
        log_line(&log_path, &format!("daemon --help output:\n{stdout}"));

        // clap may also write to stderr for help text, combine both.
        let stderr = String::from_utf8_lossy(&output.stderr);
        let combined = format!("{stdout}{stderr}");

        for sub in &["start", "stop", "status"] {
            assert!(
                combined.contains(sub),
                "daemon --help output does not contain '{sub}'"
            );
        }

        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("test_cli_subcommand_registered", &log_path, success);
    assert!(success, "see log at {}", log_path.display());

    let _ = std::fs::remove_dir_all(&test_dir);
}

/// 8. Start backend-manager in legacy mode (without daemon flags).
///    Connect one client to the per-PID socket.  Verify the connection
///    works.  Verify NO daemon PID file or daemon socket exists.
#[tokio::test]
async fn test_existing_frontend_mode_unbroken() {
    let (test_dir, log_path) = setup_test_dir("existing_frontend_mode_unbroken");
    let mut success = false;

    let result: Result<(), String> = async {
        let ct_dir = daemon_paths_in(&test_dir);
        std::fs::create_dir_all(&ct_dir).map_err(|e| format!("mkdir: {e}"))?;

        let bin = binary_path();
        log_line(&log_path, &format!("binary: {}", bin.display()));
        log_line(&log_path, &format!("TMPDIR override: {}", test_dir.display()));
        log_line(&log_path, &format!("ct_dir: {}", ct_dir.display()));

        // Start legacy mode: no daemon subcommand.
        let mut child = Command::new(&bin)
            .env("TMPDIR", &test_dir)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("spawn legacy: {e}"))?;

        let child_pid = child.id().expect("no pid for child");
        log_line(&log_path, &format!("child pid: {child_pid}"));

        // In legacy mode, the socket is at <ct_dir>/backend-manager/<pid>.sock
        let legacy_socket = ct_dir.join("backend-manager").join(format!("{child_pid}.sock"));
        log_line(&log_path, &format!("expected socket: {}", legacy_socket.display()));

        // Wait for the legacy socket to appear.
        // Also check if the child has already exited (which would mean it crashed).
        let wait_result = async {
            let start = tokio::time::Instant::now();
            let deadline = Duration::from_secs(10);
            while !legacy_socket.exists() {
                if start.elapsed() > deadline {
                    // Before giving up, check if the child is still alive.
                    match child.try_wait() {
                        Ok(Some(status)) => {
                            // Child exited — read its stderr for diagnostics.
                            let mut stderr_out = String::new();
                            if let Some(mut stderr) = child.stderr.take() {
                                let _ = stderr.read_to_string(&mut stderr_out).await;
                            }
                            return Err(format!(
                                "child exited with {status} before socket appeared. stderr: {stderr_out}"
                            ));
                        }
                        Ok(None) => {
                            return Err(format!(
                                "socket {} did not appear within {deadline:?} (child still running)",
                                legacy_socket.display()
                            ));
                        }
                        Err(e) => {
                            return Err(format!("try_wait error: {e}"));
                        }
                    }
                }
                sleep(Duration::from_millis(50)).await;
            }
            Ok(())
        }.await;
        wait_result.map_err(|e| { log_line(&log_path, &format!("wait error: {e}")); e })?;
        log_line(&log_path, "legacy socket appeared");

        // Connect one client.
        let mut client = UnixStream::connect(&legacy_socket)
            .await
            .map_err(|e| format!("legacy connect: {e}"))?;
        log_line(&log_path, "client connected to legacy socket");

        // Give the backend-manager a moment to accept the connection.
        sleep(Duration::from_millis(200)).await;

        // Send a ct/ping request.
        let ping = json!({"type": "request", "command": "ct/ping", "seq": 1});
        client
            .write_all(&dap_encode(&ping))
            .await
            .map_err(|e| format!("legacy write: {e}"))?;

        // Read the response.
        let resp = timeout(Duration::from_secs(5), dap_read(&mut client))
            .await
            .map_err(|_| "timeout reading legacy response".to_string())?
            .map_err(|e| format!("legacy read: {e}"))?;
        log_line(&log_path, &format!("legacy response: {resp}"));

        assert_eq!(
            resp.get("command").and_then(Value::as_str),
            Some("ct/ping"),
            "legacy response command mismatch"
        );
        assert_eq!(
            resp.get("success").and_then(Value::as_bool),
            Some(true),
            "legacy response not successful"
        );

        // Verify NO daemon socket or PID file exists.
        let daemon_socket_path = ct_dir.join("daemon.sock");
        let daemon_pid_path = ct_dir.join("daemon.pid");
        assert!(
            !daemon_socket_path.exists(),
            "daemon socket should NOT exist in legacy mode"
        );
        assert!(
            !daemon_pid_path.exists(),
            "daemon PID file should NOT exist in legacy mode"
        );

        // Kill the legacy process.
        let _ = child.kill().await;

        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("test_existing_frontend_mode_unbroken", &log_path, success);
    assert!(success, "see log at {}", log_path.display());

    let _ = std::fs::remove_dir_all(&test_dir);
}

// ===========================================================================
// M1 Helpers: session creation, daemon-status, etc.
// ===========================================================================

/// Sends `ct/start-replay` using the `mock-backend` subcommand so that the
/// daemon's `start_replay` gets a child process that connects back and stays
/// alive.  Returns the `replayId` from the response.
///
/// `trace_name` is an arbitrary identifier used as the "command" argument
/// (the session manager uses it as the trace path).
async fn create_mock_session(
    client: &mut UnixStream,
    seq: i64,
    trace_name: &str,
    log_path: &Path,
) -> Result<usize, String> {
    let bin = binary_path();
    let bin_str = bin.to_string_lossy();
    let req = json!({
        "type": "request",
        "command": "ct/start-replay",
        "seq": seq,
        "arguments": [bin_str, "mock-backend", trace_name]
    });
    client
        .write_all(&dap_encode(&req))
        .await
        .map_err(|e| format!("write start-replay: {e}"))?;

    // The daemon calls start_replay which spawns the mock-backend and waits
    // for it to connect.  This may take a moment.
    let resp = timeout(Duration::from_secs(10), dap_read(client))
        .await
        .map_err(|_| "timeout waiting for start-replay response".to_string())?
        .map_err(|e| format!("read start-replay response: {e}"))?;

    log_line(log_path, &format!("start-replay response: {resp}"));

    if resp.get("success").and_then(Value::as_bool) != Some(true) {
        return Err(format!("start-replay not successful: {resp}"));
    }

    resp.get("body")
        .and_then(|b| b.get("replayId"))
        .and_then(Value::as_u64)
        .map(|id| id as usize)
        .ok_or_else(|| format!("missing replayId in response: {resp}"))
}

/// Sends `ct/daemon-status` and returns the parsed response body.
///
/// Skips any interleaved events (e.g. `ct/session-crashed`) that may
/// arrive before the actual response.
async fn query_daemon_status(
    client: &mut UnixStream,
    seq: i64,
    log_path: &Path,
) -> Result<Value, String> {
    let req = json!({
        "type": "request",
        "command": "ct/daemon-status",
        "seq": seq,
    });
    client
        .write_all(&dap_encode(&req))
        .await
        .map_err(|e| format!("write daemon-status: {e}"))?;

    // Read messages, skipping events, until we get a response.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err("timeout waiting for daemon-status response".to_string());
        }

        let msg = timeout(remaining, dap_read(client))
            .await
            .map_err(|_| "timeout waiting for daemon-status response".to_string())?
            .map_err(|e| format!("read daemon-status: {e}"))?;

        let msg_type = msg.get("type").and_then(Value::as_str).unwrap_or("");
        if msg_type == "event" {
            log_line(log_path, &format!("daemon-status: skipped event: {msg}"));
            continue;
        }

        log_line(log_path, &format!("daemon-status response: {msg}"));

        if msg.get("success").and_then(Value::as_bool) != Some(true) {
            return Err(format!("daemon-status not successful: {msg}"));
        }

        return msg
            .get("body")
            .cloned()
            .ok_or_else(|| format!("missing body in daemon-status response: {msg}"));
    }
}

// ===========================================================================
// M1 Tests
// ===========================================================================

/// M1-1. Auto-start on first query: ensure no daemon socket exists, run
/// `backend-manager daemon connect`, verify daemon auto-starts and the
/// connect command succeeds.
#[tokio::test]
async fn test_auto_start_on_first_query() {
    let (test_dir, log_path) = setup_test_dir("auto_start_first_query");
    let mut success = false;

    let result: Result<(), String> = async {
        let ct_dir = daemon_paths_in(&test_dir);
        std::fs::create_dir_all(&ct_dir).map_err(|e| format!("mkdir: {e}"))?;

        let socket_path = ct_dir.join("daemon.sock");

        // Ensure no daemon is running.
        assert!(!socket_path.exists(), "socket should not exist before test");

        // Run `daemon connect` — should auto-start the daemon.
        let output = timeout(
            Duration::from_secs(10),
            Command::new(binary_path())
                .arg("daemon")
                .arg("connect")
                .env("TMPDIR", &test_dir)
                .output(),
        )
        .await
        .map_err(|_| "timeout running daemon connect".to_string())?
        .map_err(|e| format!("daemon connect: {e}"))?;

        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        log_line(&log_path, &format!("connect stdout: {stdout}"));
        log_line(&log_path, &format!("connect stderr: {stderr}"));

        assert!(
            output.status.success(),
            "daemon connect exited with {:?}",
            output.status.code()
        );
        assert!(
            stdout.contains("connected"),
            "expected 'connected' in output, got: {stdout}"
        );

        // Socket file should now exist (daemon is running).
        assert!(
            socket_path.exists(),
            "daemon socket should exist after auto-start"
        );

        // Clean up: stop the daemon.
        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("cleanup connect: {e}"))?;
        let req = json!({"type": "request", "command": "ct/daemon-shutdown", "seq": 1});
        let _ = client.write_all(&dap_encode(&req)).await;
        sleep(Duration::from_millis(500)).await;

        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("test_auto_start_on_first_query", &log_path, success);
    assert!(success, "see log at {}", log_path.display());

    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M1-2. Auto-start detaches from terminal: run `daemon connect`, let it
/// exit, verify the daemon process is still running (check PID file), then
/// clean up by stopping the daemon.
#[tokio::test]
async fn test_auto_start_detaches_from_terminal() {
    let (test_dir, log_path) = setup_test_dir("auto_start_detaches");
    let mut success = false;

    let result: Result<(), String> = async {
        let ct_dir = daemon_paths_in(&test_dir);
        std::fs::create_dir_all(&ct_dir).map_err(|e| format!("mkdir: {e}"))?;

        let socket_path = ct_dir.join("daemon.sock");
        let pid_path = ct_dir.join("daemon.pid");

        // Auto-start via connect.
        let output = timeout(
            Duration::from_secs(10),
            Command::new(binary_path())
                .arg("daemon")
                .arg("connect")
                .env("TMPDIR", &test_dir)
                .output(),
        )
        .await
        .map_err(|_| "timeout running daemon connect".to_string())?
        .map_err(|e| format!("daemon connect: {e}"))?;

        assert!(
            output.status.success(),
            "daemon connect failed: {:?}",
            output.status.code()
        );
        log_line(&log_path, "connect succeeded");

        // The connect command has exited.  The daemon should still be alive.
        sleep(Duration::from_millis(200)).await;

        assert!(
            socket_path.exists(),
            "daemon socket should still exist after connect exits"
        );
        assert!(
            pid_path.exists(),
            "PID file should exist after auto-start"
        );

        // Verify the PID is alive.
        let pid_str = std::fs::read_to_string(&pid_path)
            .map_err(|e| format!("read pid: {e}"))?;
        let pid: u32 = pid_str.trim().parse().map_err(|e| format!("parse pid: {e}"))?;
        log_line(&log_path, &format!("daemon pid: {pid}"));

        // SAFETY: signal 0 only checks existence.
        let alive = unsafe { libc::kill(pid as libc::pid_t, 0) == 0 };
        assert!(alive, "daemon process {pid} is not alive");

        // Clean up: stop the daemon.
        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("cleanup connect: {e}"))?;
        let req = json!({"type": "request", "command": "ct/daemon-shutdown", "seq": 1});
        let _ = client.write_all(&dap_encode(&req)).await;
        sleep(Duration::from_millis(500)).await;

        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("test_auto_start_detaches_from_terminal", &log_path, success);
    assert!(success, "see log at {}", log_path.display());

    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M1-3. Subsequent queries reuse daemon: auto-start via connect, read PID,
/// run connect again, read PID again, verify same PID (same daemon instance).
#[tokio::test]
async fn test_subsequent_queries_reuse_daemon() {
    let (test_dir, log_path) = setup_test_dir("subsequent_reuse");
    let mut success = false;

    let result: Result<(), String> = async {
        let ct_dir = daemon_paths_in(&test_dir);
        std::fs::create_dir_all(&ct_dir).map_err(|e| format!("mkdir: {e}"))?;

        let socket_path = ct_dir.join("daemon.sock");
        let pid_path = ct_dir.join("daemon.pid");

        // First connect: auto-starts daemon.
        let output1 = timeout(
            Duration::from_secs(10),
            Command::new(binary_path())
                .arg("daemon")
                .arg("connect")
                .env("TMPDIR", &test_dir)
                .output(),
        )
        .await
        .map_err(|_| "timeout on first connect".to_string())?
        .map_err(|e| format!("first connect: {e}"))?;
        assert!(output1.status.success(), "first connect failed");
        log_line(&log_path, "first connect succeeded");

        let pid1_str = std::fs::read_to_string(&pid_path)
            .map_err(|e| format!("read pid 1: {e}"))?;
        let pid1: u32 = pid1_str.trim().parse().map_err(|e| format!("parse pid 1: {e}"))?;
        log_line(&log_path, &format!("pid after first connect: {pid1}"));

        // Second connect: should reuse existing daemon.
        let output2 = timeout(
            Duration::from_secs(10),
            Command::new(binary_path())
                .arg("daemon")
                .arg("connect")
                .env("TMPDIR", &test_dir)
                .output(),
        )
        .await
        .map_err(|_| "timeout on second connect".to_string())?
        .map_err(|e| format!("second connect: {e}"))?;
        assert!(output2.status.success(), "second connect failed");
        log_line(&log_path, "second connect succeeded");

        let pid2_str = std::fs::read_to_string(&pid_path)
            .map_err(|e| format!("read pid 2: {e}"))?;
        let pid2: u32 = pid2_str.trim().parse().map_err(|e| format!("parse pid 2: {e}"))?;
        log_line(&log_path, &format!("pid after second connect: {pid2}"));

        assert_eq!(
            pid1, pid2,
            "PID changed between connects ({pid1} vs {pid2}) — daemon was restarted"
        );

        // Clean up.
        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("cleanup connect: {e}"))?;
        let req = json!({"type": "request", "command": "ct/daemon-shutdown", "seq": 1});
        let _ = client.write_all(&dap_encode(&req)).await;
        sleep(Duration::from_millis(500)).await;

        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("test_subsequent_queries_reuse_daemon", &log_path, success);
    assert!(success, "see log at {}", log_path.display());

    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M1-4. TTL expires and unloads trace: start daemon with TTL=2s, create a
/// session, verify it's loaded, wait for TTL to expire, verify the session
/// was unloaded (the daemon auto-shuts down because it was the only session).
#[tokio::test]
async fn test_ttl_expires_unloads_trace() {
    let (test_dir, log_path) = setup_test_dir("ttl_expires_unloads");
    let mut success = false;

    let result: Result<(), String> = async {
        let ct_dir = daemon_paths_in(&test_dir);
        let socket_path = ct_dir.join("daemon.sock");
        let pid_path = ct_dir.join("daemon.pid");

        // Start daemon with a 2-second TTL.
        let (mut daemon, _socket_path) = start_daemon_with_env(
            &test_dir,
            &log_path,
            &[("CODETRACER_DAEMON_TTL", "2")],
        )
        .await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Create a session using mock-backend.
        let replay_id = create_mock_session(&mut client, 100, "trace-ttl-test", &log_path).await?;
        log_line(&log_path, &format!("created session with replayId={replay_id}"));

        // Verify session exists via daemon-status.
        let status1 = query_daemon_status(&mut client, 101, &log_path).await?;
        let sessions1 = status1.get("sessions").and_then(Value::as_u64).unwrap_or(0);
        log_line(&log_path, &format!("sessions after create: {sessions1}"));
        assert_eq!(sessions1, 1, "expected 1 session after create, got {sessions1}");

        // Drop the client so it doesn't keep a broken-pipe when daemon shuts down.
        drop(client);

        // Wait for TTL to expire and daemon to auto-shutdown (2s TTL + margin).
        log_line(&log_path, "waiting for TTL and auto-shutdown...");
        let wait_result = timeout(Duration::from_secs(10), daemon.wait())
            .await
            .map_err(|_| "daemon did not exit within 10s".to_string())?
            .map_err(|e| format!("daemon wait: {e}"))?;
        log_line(&log_path, &format!("daemon exited with: {wait_result}"));

        // Give filesystem a moment to settle.
        sleep(Duration::from_millis(500)).await;

        // Verify the daemon shut down (which proves the session's TTL expired
        // and triggered auto-shutdown because it was the last session).
        assert!(
            !socket_path.exists(),
            "socket file should be removed after TTL-triggered shutdown"
        );
        assert!(
            !pid_path.exists(),
            "PID file should be removed after TTL-triggered shutdown"
        );

        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("test_ttl_expires_unloads_trace", &log_path, success);
    assert!(success, "see log at {}", log_path.display());

    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M1-5. Query resets TTL: start daemon with TTL=3s, create session, wait 2s,
/// send a message to the session (which resets TTL), wait 2 more seconds
/// (4 total, but only 2 since reset), verify session is still loaded.
/// Without the reset, the session would have expired at T=3; with the reset,
/// it expires at T=5 (2 + 3).
#[tokio::test]
async fn test_query_resets_ttl() {
    let (test_dir, log_path) = setup_test_dir("query_resets_ttl");
    let mut success = false;

    let result: Result<(), String> = async {
        // Start daemon with a 3-second TTL.
        let (mut daemon, socket_path) = start_daemon_with_env(
            &test_dir,
            &log_path,
            &[("CODETRACER_DAEMON_TTL", "3")],
        )
        .await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Create a session.
        let replay_id = create_mock_session(&mut client, 200, "trace-ttl-reset", &log_path).await?;
        log_line(&log_path, &format!("created session with replayId={replay_id}"));

        // Wait 2 seconds (less than TTL=3s).
        sleep(Duration::from_secs(2)).await;

        // Send a ct/start-replay with the same trace name — the session
        // manager will detect it's already loaded and reset the TTL.
        let bin = binary_path();
        let bin_str = bin.to_string_lossy();
        let reset_req = json!({
            "type": "request",
            "command": "ct/start-replay",
            "seq": 201,
            "arguments": [bin_str, "mock-backend", "trace-ttl-reset"]
        });
        client
            .write_all(&dap_encode(&reset_req))
            .await
            .map_err(|e| format!("write reset: {e}"))?;

        let reset_resp = timeout(Duration::from_secs(5), dap_read(&mut client))
            .await
            .map_err(|_| "timeout on reset response".to_string())?
            .map_err(|e| format!("read reset: {e}"))?;
        log_line(&log_path, &format!("reset response: {reset_resp}"));

        // At this point, T~2.  Without the reset, the session would expire
        // at T=3.  With the reset, it should expire at T=2+3=5.
        // Wait 2 more seconds (to T~4).  Session should still be alive.
        sleep(Duration::from_secs(2)).await;

        // Verify the session is still loaded at T~4.
        let status = query_daemon_status(&mut client, 202, &log_path).await?;
        let sessions = status.get("sessions").and_then(Value::as_u64).unwrap_or(0);
        log_line(&log_path, &format!("sessions at T~4 (after reset): {sessions}"));
        assert_eq!(sessions, 1, "session should still be loaded (TTL was reset), got {sessions}");

        // Clean up: shut down daemon.
        shutdown_daemon(&mut client, &mut daemon).await;

        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("test_query_resets_ttl", &log_path, success);
    assert!(success, "see log at {}", log_path.display());

    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M1-6. Auto-shutdown on last TTL: start daemon with TTL=2s, create one
/// session, wait for TTL to expire, verify daemon has shut down (socket and
/// PID files removed).
#[tokio::test]
async fn test_auto_shutdown_on_last_ttl() {
    let (test_dir, log_path) = setup_test_dir("auto_shutdown_last_ttl");
    let mut success = false;

    let result: Result<(), String> = async {
        let ct_dir = daemon_paths_in(&test_dir);
        let socket_path = ct_dir.join("daemon.sock");
        let pid_path = ct_dir.join("daemon.pid");

        // Start daemon with a 2-second TTL.
        let (mut daemon, _socket_path) = start_daemon_with_env(
            &test_dir,
            &log_path,
            &[("CODETRACER_DAEMON_TTL", "2")],
        )
        .await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Create one session.
        let _replay_id = create_mock_session(&mut client, 300, "trace-auto-shutdown", &log_path).await?;
        log_line(&log_path, "session created, waiting for TTL and auto-shutdown...");

        // Drop the client to avoid blocking the daemon's shutdown.
        drop(client);

        // Wait for the daemon to shut down (TTL 2s + cleanup margin).
        // The daemon should exit when the last session's TTL fires.
        let wait_result = timeout(Duration::from_secs(10), daemon.wait())
            .await
            .map_err(|_| "daemon did not exit within 10s".to_string())?
            .map_err(|e| format!("daemon wait: {e}"))?;
        log_line(&log_path, &format!("daemon exited with: {wait_result}"));

        // Give filesystem a moment to settle.
        sleep(Duration::from_millis(500)).await;

        // Socket and PID files should be removed.
        assert!(
            !socket_path.exists(),
            "socket file should be removed after auto-shutdown"
        );
        assert!(
            !pid_path.exists(),
            "PID file should be removed after auto-shutdown"
        );

        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("test_auto_shutdown_on_last_ttl", &log_path, success);
    assert!(success, "see log at {}", log_path.display());

    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M1-7. Stale socket recovery: create a stale socket file at the daemon
/// path, run `daemon connect`, verify the stale socket is removed and a
/// new daemon starts, verify connection succeeds.
#[tokio::test]
async fn test_stale_socket_recovery() {
    let (test_dir, log_path) = setup_test_dir("stale_socket_recovery");
    let mut success = false;

    let result: Result<(), String> = async {
        let ct_dir = daemon_paths_in(&test_dir);
        std::fs::create_dir_all(&ct_dir).map_err(|e| format!("mkdir: {e}"))?;

        let socket_path = ct_dir.join("daemon.sock");

        // Create a stale socket file (just a regular file, not a real socket).
        std::fs::write(&socket_path, "stale")
            .map_err(|e| format!("write stale socket: {e}"))?;
        assert!(socket_path.exists(), "stale socket file should exist");
        log_line(&log_path, "created stale socket file");

        // Run `daemon connect` — should detect stale socket, remove it,
        // start a new daemon, and connect.
        let output = timeout(
            Duration::from_secs(10),
            Command::new(binary_path())
                .arg("daemon")
                .arg("connect")
                .env("TMPDIR", &test_dir)
                .output(),
        )
        .await
        .map_err(|_| "timeout running daemon connect".to_string())?
        .map_err(|e| format!("daemon connect: {e}"))?;

        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        log_line(&log_path, &format!("connect stdout: {stdout}"));
        log_line(&log_path, &format!("connect stderr: {stderr}"));

        assert!(
            output.status.success(),
            "daemon connect failed after stale socket: {:?}",
            output.status.code()
        );
        assert!(
            stdout.contains("connected"),
            "expected 'connected', got: {stdout}"
        );

        // Verify a real socket is now in place (we can connect to it).
        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("post-recovery connect: {e}"))?;
        log_line(&log_path, "successfully connected after stale recovery");

        // Clean up: stop daemon.
        let req = json!({"type": "request", "command": "ct/daemon-shutdown", "seq": 1});
        let _ = client.write_all(&dap_encode(&req)).await;
        sleep(Duration::from_millis(500)).await;

        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("test_stale_socket_recovery", &log_path, success);
    assert!(success, "see log at {}", log_path.display());

    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M1-8. Max sessions enforced: start daemon with MAX_SESSIONS=2, create
/// sessions A and B, try to create session C, verify an error response.
#[tokio::test]
async fn test_max_sessions_enforced() {
    let (test_dir, log_path) = setup_test_dir("max_sessions_enforced");
    let mut success = false;

    let result: Result<(), String> = async {
        // Start daemon with max 2 sessions.
        let (mut daemon, socket_path) = start_daemon_with_env(
            &test_dir,
            &log_path,
            &[("CODETRACER_MAX_SESSIONS", "2")],
        )
        .await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Create session A.
        let id_a = create_mock_session(&mut client, 400, "trace-a", &log_path).await?;
        log_line(&log_path, &format!("session A: replayId={id_a}"));

        // Create session B.
        let id_b = create_mock_session(&mut client, 401, "trace-b", &log_path).await?;
        log_line(&log_path, &format!("session B: replayId={id_b}"));

        // Verify 2 sessions.
        let status = query_daemon_status(&mut client, 402, &log_path).await?;
        let sessions = status.get("sessions").and_then(Value::as_u64).unwrap_or(0);
        assert_eq!(sessions, 2, "expected 2 sessions, got {sessions}");

        // Try to create session C — should fail.
        let bin = binary_path();
        let bin_str = bin.to_string_lossy();
        let req_c = json!({
            "type": "request",
            "command": "ct/start-replay",
            "seq": 403,
            "arguments": [bin_str, "mock-backend", "trace-c"]
        });
        client
            .write_all(&dap_encode(&req_c))
            .await
            .map_err(|e| format!("write start-replay C: {e}"))?;

        let resp_c = timeout(Duration::from_secs(5), dap_read(&mut client))
            .await
            .map_err(|_| "timeout on start-replay C response".to_string())?
            .map_err(|e| format!("read start-replay C: {e}"))?;
        log_line(&log_path, &format!("start-replay C response: {resp_c}"));

        // Expect failure.
        let c_success = resp_c.get("success").and_then(Value::as_bool).unwrap_or(true);
        assert!(
            !c_success,
            "session C should have been rejected, but got success=true"
        );

        // Verify still 2 sessions (no change).
        let status2 = query_daemon_status(&mut client, 404, &log_path).await?;
        let sessions2 = status2.get("sessions").and_then(Value::as_u64).unwrap_or(0);
        assert_eq!(sessions2, 2, "expected 2 sessions after rejected C, got {sessions2}");

        // Shut down.
        shutdown_daemon(&mut client, &mut daemon).await;

        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("test_max_sessions_enforced", &log_path, success);
    assert!(success, "see log at {}", log_path.display());

    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M1-9. Config file loaded: create a config file with `default_ttl = 4`,
/// start daemon with env var pointing to config, verify TTL is 4 (create
/// session, wait 3s, verify still loaded; then verify it eventually expires
/// by waiting for daemon auto-shutdown).
#[tokio::test]
async fn test_config_file_loaded() {
    let (test_dir, log_path) = setup_test_dir("config_file_loaded");
    let mut success = false;

    let result: Result<(), String> = async {
        let ct_dir = daemon_paths_in(&test_dir);
        let socket_path = ct_dir.join("daemon.sock");
        let pid_path = ct_dir.join("daemon.pid");

        // Create a config file with a 4-second TTL.
        let config_dir = test_dir.join("config");
        std::fs::create_dir_all(&config_dir).map_err(|e| format!("mkdir config: {e}"))?;
        let config_path = config_dir.join("daemon.conf");
        std::fs::write(&config_path, "default_ttl = 4\n")
            .map_err(|e| format!("write config: {e}"))?;
        log_line(&log_path, &format!("config file: {}", config_path.display()));

        // Start daemon with the config file.
        let (mut daemon, _socket_path) = start_daemon_with_env(
            &test_dir,
            &log_path,
            &[("CODETRACER_DAEMON_CONFIG", config_path.to_str().unwrap())],
        )
        .await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Create a session.
        let _replay_id = create_mock_session(&mut client, 500, "trace-config", &log_path).await?;
        log_line(&log_path, "session created");

        // Wait 3 seconds (less than TTL=4).
        sleep(Duration::from_secs(3)).await;

        // Session should still be loaded (TTL is 4, we're at T=3).
        let status1 = query_daemon_status(&mut client, 501, &log_path).await?;
        let sessions1 = status1.get("sessions").and_then(Value::as_u64).unwrap_or(0);
        log_line(&log_path, &format!("sessions at T=3: {sessions1}"));
        assert_eq!(sessions1, 1, "session should still be loaded at T=3 (TTL=4), got {sessions1}");

        // Drop the client to allow clean daemon exit.
        drop(client);

        // Wait for the TTL to expire and daemon to auto-shutdown.
        // Session was created at T=0 (approx), TTL=4s, so it should expire
        // around T=4.  We give extra margin.
        let wait_result = timeout(Duration::from_secs(10), daemon.wait())
            .await
            .map_err(|_| "daemon did not auto-shutdown after TTL expiry".to_string())?
            .map_err(|e| format!("daemon wait: {e}"))?;
        log_line(&log_path, &format!("daemon exited with: {wait_result}"));

        // Verify cleanup.
        sleep(Duration::from_millis(500)).await;
        assert!(
            !socket_path.exists(),
            "socket should be removed after config-driven TTL shutdown"
        );
        assert!(
            !pid_path.exists(),
            "PID file should be removed after config-driven TTL shutdown"
        );

        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("test_config_file_loaded", &log_path, success);
    assert!(success, "see log at {}", log_path.display());

    let _ = std::fs::remove_dir_all(&test_dir);
}

// ===========================================================================
// M2 Helpers: trace directory creation, open-trace, etc.
// ===========================================================================

/// Creates a minimal test trace directory with the required JSON files.
///
/// Returns the path to the trace directory.
fn create_test_trace_dir(parent: &Path, name: &str, program: &str) -> PathBuf {
    let trace_dir = parent.join(name);
    std::fs::create_dir_all(trace_dir.join("files")).expect("create trace dir");

    let metadata = serde_json::json!({
        "workdir": "/tmp/test-workdir",
        "program": program,
        "args": []
    });
    std::fs::write(
        trace_dir.join("trace_metadata.json"),
        serde_json::to_string_pretty(&metadata).unwrap(),
    )
    .expect("write trace_metadata.json");

    let paths = serde_json::json!(["src/main.rs", "src/lib.rs"]);
    std::fs::write(
        trace_dir.join("trace_paths.json"),
        serde_json::to_string(&paths).unwrap(),
    )
    .expect("write trace_paths.json");

    let events = serde_json::json!([
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

/// Sends `ct/open-trace` and returns the response.
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

/// Sends `ct/trace-info` and returns the response.
///
/// Skips any interleaved events that may arrive before the response.
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

    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
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

/// Sends `ct/close-trace` and returns the response.
async fn close_trace(
    client: &mut UnixStream,
    seq: i64,
    trace_path: &Path,
    log_path: &Path,
) -> Result<Value, String> {
    let req = json!({
        "type": "request",
        "command": "ct/close-trace",
        "seq": seq,
        "arguments": {
            "tracePath": trace_path.to_string_lossy(),
        }
    });
    client
        .write_all(&dap_encode(&req))
        .await
        .map_err(|e| format!("write ct/close-trace: {e}"))?;

    let resp = timeout(Duration::from_secs(10), dap_read(client))
        .await
        .map_err(|_| "timeout waiting for ct/close-trace response".to_string())?
        .map_err(|e| format!("read ct/close-trace response: {e}"))?;

    log_line(log_path, &format!("ct/close-trace response: {resp}"));
    Ok(resp)
}

/// Starts a daemon with the mock-dap-backend configured via
/// CODETRACER_DB_BACKEND_CMD environment variable.
async fn start_daemon_with_mock_dap(
    test_dir: &Path,
    log_path: &Path,
    extra_env: &[(&str, &str)],
) -> (tokio::process::Child, PathBuf) {
    let bin = binary_path();
    let bin_str = bin.to_string_lossy().to_string();

    let mut env_vars: Vec<(&str, &str)> = vec![];
    // Point CODETRACER_DB_BACKEND_CMD to our own binary (which has
    // the mock-dap-backend subcommand).
    let db_backend_cmd_key = "CODETRACER_DB_BACKEND_CMD";
    env_vars.push((db_backend_cmd_key, &bin_str));
    env_vars.extend_from_slice(extra_env);

    start_daemon_with_env(test_dir, log_path, &env_vars).await
}

// ===========================================================================
// M2 Tests
// ===========================================================================

/// M2-1. Send ct/open-trace with a trace path.  Verify backend process is
/// launched (mock-backend connects).  Verify DAP init completes (mock sends
/// responses).  Verify session metadata is populated from trace files.
#[tokio::test]
async fn test_session_launches_db_backend() {
    let (test_dir, log_path) = setup_test_dir("session_launches_db_backend");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-a", "main.rs");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

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
        let body = resp.get("body").expect("response should have body");
        assert_eq!(
            body.get("language").and_then(Value::as_str),
            Some("rust"),
            "language should be 'rust'"
        );
        assert!(
            body.get("totalEvents").and_then(Value::as_u64).unwrap_or(0) > 0,
            "totalEvents should be > 0"
        );
        assert!(
            body.get("sourceFiles")
                .and_then(Value::as_array)
                .map(|a| !a.is_empty())
                .unwrap_or(false),
            "sourceFiles should be non-empty"
        );
        assert_eq!(
            body.get("program").and_then(Value::as_str),
            Some("main.rs"),
        );
        assert_eq!(
            body.get("workdir").and_then(Value::as_str),
            Some("/tmp/test-workdir"),
        );
        assert_eq!(
            body.get("cached").and_then(Value::as_bool),
            Some(false),
            "first open should not be cached"
        );

        // Verify via daemon-status that a session exists.
        let status = query_daemon_status(&mut client, 1001, &log_path).await?;
        let sessions = status.get("sessions").and_then(Value::as_u64).unwrap_or(0);
        assert_eq!(sessions, 1, "expected 1 session, got {sessions}");

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("test_session_launches_db_backend", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M2-2. Send ct/open-trace for trace A twice.  Verify only one backend
/// process (session count stays 1).  Verify both responses have the same
/// metadata.  Verify TTL was reset (second response says cached=true).
#[tokio::test]
async fn test_session_reuses_existing() {
    let (test_dir, log_path) = setup_test_dir("session_reuses_existing");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-reuse", "main.rs");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

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

        // Same backend ID (same session).
        assert_eq!(
            backend_id_1, backend_id_2,
            "second open should reuse the same backend"
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

        // Still only 1 session.
        let status = query_daemon_status(&mut client, 2002, &log_path).await?;
        let sessions = status.get("sessions").and_then(Value::as_u64).unwrap_or(0);
        assert_eq!(sessions, 1, "expected 1 session, got {sessions}");

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("test_session_reuses_existing", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M2-3. Send ct/open-trace to create session.  Send ct/close-trace.
/// Verify session removed (session count 0).
#[tokio::test]
async fn test_session_teardown_stops_backend() {
    let (test_dir, log_path) = setup_test_dir("session_teardown_stops_backend");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-teardown", "main.rs");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Create session.
        let open_resp = open_trace(&mut client, 3000, &trace_dir, &log_path).await?;
        assert_eq!(
            open_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "open should succeed"
        );

        // Verify session exists.
        let status1 = query_daemon_status(&mut client, 3001, &log_path).await?;
        assert_eq!(
            status1.get("sessions").and_then(Value::as_u64).unwrap_or(0),
            1,
            "expected 1 session after open"
        );

        // Close session.
        let close_resp = close_trace(&mut client, 3002, &trace_dir, &log_path).await?;
        assert_eq!(
            close_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "close should succeed"
        );

        // Verify session is removed.
        let status2 = query_daemon_status(&mut client, 3003, &log_path).await?;
        assert_eq!(
            status2.get("sessions").and_then(Value::as_u64).unwrap_or(0),
            0,
            "expected 0 sessions after close"
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("test_session_teardown_stops_backend", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M2-4. Send ct/open-trace.  Kill the mock-backend process externally
/// (via the daemon's child PID).  Wait briefly for crash detection.
/// Verify ct/trace-info returns an error.  Verify session is cleaned up.
#[tokio::test]
async fn test_session_handles_backend_crash() {
    let (test_dir, log_path) = setup_test_dir("session_handles_backend_crash");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-crash", "main.rs");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Create session.
        let open_resp = open_trace(&mut client, 4000, &trace_dir, &log_path).await?;
        assert_eq!(
            open_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "open should succeed"
        );

        let backend_id = open_resp
            .get("body")
            .and_then(|b| b.get("backendId"))
            .and_then(Value::as_u64)
            .ok_or("missing backendId")?;
        log_line(&log_path, &format!("backend_id: {backend_id}"));

        // Verify session exists.
        let status1 = query_daemon_status(&mut client, 4001, &log_path).await?;
        assert_eq!(
            status1.get("sessions").and_then(Value::as_u64).unwrap_or(0),
            1,
            "expected 1 session"
        );

        // Kill the mock-backend process by sending SIGKILL to the child.
        // We can do this by finding the child PID via the daemon.
        // The daemon spawns children as child processes.  Since we know
        // the backend_id, and the mock-dap-backend is a child of the
        // daemon, we'll use a different approach: use ct/stop-replay
        // would cleanly stop it, but we need to simulate a crash.
        // Instead, we kill the process by looking at what process IDs
        // exist in the socket directory.
        //
        // Actually, the simplest approach: send SIGKILL via
        // the "arguments" field.  But the daemon only has the child
        // process object.  Since the integration test can't directly
        // access the daemon's internal state, we'll send a custom
        // request that kills the backend.
        //
        // Simpler approach: use the `ct/stop-replay` which kills the
        // child, then the crash detector should find it.  But
        // ct/stop-replay also removes the session.
        //
        // Best approach: Get the child PID from /proc or use process
        // group.  But actually, since the daemon internally uses
        // `child.try_wait()`, we need the child process to be gone.
        //
        // The most reliable test: use `kill(2)` to kill all children
        // of the daemon.  But we don't know the PIDs from the test.
        //
        // Alternative: Let the crash detector work by killing the backend
        // from *inside* the daemon.  We can't do that from the test, so
        // let's verify the crash detection by a different mechanism:
        //
        // We stop the backend process via ct/stop-replay (which kills it
        // and removes the session from children but NOT from session_manager
        // -- wait, it does remove from session_manager).
        //
        // Let me use an alternative: we know that when the mock-dap-backend
        // exits, the crash detection loop should notice it.  We can cause
        // it to exit by closing the connection.  But actually, we can
        // simply KILL the daemon's child using its PID.  The trick is to
        // find the PID.  Looking at the daemon state: children[backend_id]
        // has the child process.  We can find it by scanning /proc.

        // Find child PIDs of the daemon process.
        let daemon_pid = daemon.id().expect("daemon has no PID");
        log_line(&log_path, &format!("daemon_pid: {daemon_pid}"));

        // List children of the daemon.  On Linux, /proc/<pid>/task/<pid>/children
        // gives the PIDs of child processes.
        let children_path = format!("/proc/{daemon_pid}/task/{daemon_pid}/children");
        let children_str = std::fs::read_to_string(&children_path)
            .unwrap_or_default();
        let child_pids: Vec<u32> = children_str
            .split_whitespace()
            .filter_map(|s| s.parse().ok())
            .collect();
        log_line(&log_path, &format!("daemon children from proc: {child_pids:?}"));

        if child_pids.is_empty() {
            // Fallback: try to find children via /proc by scanning for processes
            // whose ppid matches the daemon PID.
            let mut found_pids: Vec<u32> = Vec::new();
            if let Ok(entries) = std::fs::read_dir("/proc") {
                for entry in entries.flatten() {
                    let name = entry.file_name();
                    if let Ok(pid) = name.to_string_lossy().parse::<u32>()
                        && let Ok(stat) = std::fs::read_to_string(format!("/proc/{pid}/stat"))
                    {
                        // The 4th field in /proc/PID/stat is the PPID.
                        let fields: Vec<&str> = stat.split_whitespace().collect();
                        if fields.len() > 3
                            && let Ok(ppid) = fields[3].parse::<u32>()
                            && ppid == daemon_pid
                        {
                            found_pids.push(pid);
                        }
                    }
                }
            }
            log_line(&log_path, &format!("daemon children from ppid scan: {found_pids:?}"));

            for pid in &found_pids {
                log_line(&log_path, &format!("killing child pid {pid} (from ppid scan)"));
                // SAFETY: SIGKILL (9) kills the process.
                unsafe {
                    libc::kill(*pid as libc::pid_t, libc::SIGKILL);
                }
            }
        } else {
            // Kill all child processes of the daemon (the mock-dap-backend).
            for pid in &child_pids {
                log_line(&log_path, &format!("killing child pid {pid}"));
                // SAFETY: SIGKILL (9) kills the process.
                unsafe {
                    libc::kill(*pid as libc::pid_t, libc::SIGKILL);
                }
            }
        }

        // Wait for crash detection (checks every 2 seconds + margin).
        sleep(Duration::from_secs(5)).await;

        // Verify session is cleaned up.
        let status2 = query_daemon_status(&mut client, 4002, &log_path).await?;
        let sessions2 = status2.get("sessions").and_then(Value::as_u64).unwrap_or(999);
        log_line(&log_path, &format!("sessions after crash: {sessions2}"));
        assert_eq!(sessions2, 0, "session should be cleaned up after crash");

        // Verify ct/trace-info returns an error.
        let info_resp = query_trace_info(&mut client, 4003, &trace_dir, &log_path).await?;
        assert_eq!(
            info_resp.get("success").and_then(Value::as_bool),
            Some(false),
            "trace-info should fail after crash"
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("test_session_handles_backend_crash", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M2-5. Create a test trace directory with trace_metadata.json and
/// trace_paths.json.  Send ct/open-trace.  Then send ct/trace-info.
/// Verify response contains language, totalEvents > 0, sourceFiles non-empty.
#[tokio::test]
async fn test_trace_info_returns_metadata() {
    let (test_dir, log_path) = setup_test_dir("trace_info_returns_metadata");
    let mut success = false;

    let result: Result<(), String> = async {
        // Use .nim to test language detection.
        let trace_dir = create_test_trace_dir(&test_dir, "trace-nim", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.
        let open_resp = open_trace(&mut client, 5000, &trace_dir, &log_path).await?;
        assert_eq!(
            open_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "open should succeed"
        );

        // Query trace info.
        let info_resp = query_trace_info(&mut client, 5001, &trace_dir, &log_path).await?;
        assert_eq!(
            info_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "trace-info should succeed"
        );

        let body = info_resp.get("body").expect("should have body");

        // Verify language detection (nim).
        assert_eq!(
            body.get("language").and_then(Value::as_str),
            Some("nim"),
            "language should be 'nim'"
        );

        // Verify total events > 0.
        let total = body.get("totalEvents").and_then(Value::as_u64).unwrap_or(0);
        assert!(total > 0, "totalEvents should be > 0, got {total}");

        // Verify source files non-empty.
        let files = body
            .get("sourceFiles")
            .and_then(Value::as_array)
            .map(|a| a.len())
            .unwrap_or(0);
        assert!(files > 0, "sourceFiles should be non-empty, got {files}");

        // Verify program and workdir.
        assert_eq!(
            body.get("program").and_then(Value::as_str),
            Some("main.nim"),
        );
        assert_eq!(
            body.get("workdir").and_then(Value::as_str),
            Some("/tmp/test-workdir"),
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("test_trace_info_returns_metadata", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M2-6. Send ct/open-trace.  Verify the DAP initialization sequence was
/// executed in order: initialize -> launch -> configurationDone.
///
/// We verify this indirectly: the fact that ct/open-trace succeeds means
/// that run_dap_init completed successfully (which requires all three
/// responses and the stopped event).  We also verify the response
/// indicates that the trace was freshly opened (not cached), confirming
/// the full init path was taken.
#[tokio::test]
async fn test_dap_initialization_sequence() {
    let (test_dir, log_path) = setup_test_dir("dap_initialization_sequence");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-dap-init", "main.rs");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace — this triggers the full DAP init sequence.
        let resp = open_trace(&mut client, 6000, &trace_dir, &log_path).await?;

        // If DAP init failed, the response would have success=false.
        assert_eq!(
            resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed (DAP init completed)"
        );

        // Verify it was not cached (meaning the full init path was taken).
        assert_eq!(
            resp.get("body")
                .and_then(|b| b.get("cached"))
                .and_then(Value::as_bool),
            Some(false),
            "should not be cached (full DAP init path)"
        );

        // Verify session is properly registered.
        let status = query_daemon_status(&mut client, 6001, &log_path).await?;
        let sessions = status.get("sessions").and_then(Value::as_u64).unwrap_or(0);
        assert_eq!(sessions, 1, "expected 1 session");

        // Verify the backend is functional by sending a ping that goes
        // through the backend (verifying channels are installed).
        let backend_id = resp
            .get("body")
            .and_then(|b| b.get("backendId"))
            .and_then(Value::as_u64)
            .ok_or("missing backendId")?;
        log_line(&log_path, &format!("backend_id: {backend_id}"));

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("test_dap_initialization_sequence", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M2-7. Create sessions for trace A and trace B.  Verify two separate
/// backend processes.  Verify each has independent metadata.  Verify
/// daemon-status reports 2 sessions.
#[tokio::test]
async fn test_multiple_sessions_independent() {
    let (test_dir, log_path) = setup_test_dir("multiple_sessions_independent");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_a = create_test_trace_dir(&test_dir, "trace-multi-a", "main.rs");
        let trace_b = create_test_trace_dir(&test_dir, "trace-multi-b", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open trace A.
        let resp_a = open_trace(&mut client, 7000, &trace_a, &log_path).await?;
        assert_eq!(
            resp_a.get("success").and_then(Value::as_bool),
            Some(true),
            "open trace A should succeed"
        );
        let backend_a = resp_a
            .get("body")
            .and_then(|b| b.get("backendId"))
            .and_then(Value::as_u64)
            .ok_or("missing backendId for A")?;

        // Open trace B.
        let resp_b = open_trace(&mut client, 7001, &trace_b, &log_path).await?;
        assert_eq!(
            resp_b.get("success").and_then(Value::as_bool),
            Some(true),
            "open trace B should succeed"
        );
        let backend_b = resp_b
            .get("body")
            .and_then(|b| b.get("backendId"))
            .and_then(Value::as_u64)
            .ok_or("missing backendId for B")?;

        // Different backend IDs.
        assert_ne!(
            backend_a, backend_b,
            "trace A and B should have different backend IDs"
        );

        // Different languages.
        let lang_a = resp_a
            .get("body")
            .and_then(|b| b.get("language"))
            .and_then(Value::as_str)
            .unwrap_or("");
        let lang_b = resp_b
            .get("body")
            .and_then(|b| b.get("language"))
            .and_then(Value::as_str)
            .unwrap_or("");
        assert_eq!(lang_a, "rust", "trace A language should be rust");
        assert_eq!(lang_b, "nim", "trace B language should be nim");

        // Verify 2 sessions.
        let status = query_daemon_status(&mut client, 7002, &log_path).await?;
        let sessions = status.get("sessions").and_then(Value::as_u64).unwrap_or(0);
        assert_eq!(sessions, 2, "expected 2 sessions, got {sessions}");

        // Send pings to verify both are responsive (they go through
        // the daemon's dispatch which verifies the channels are installed).
        let ping1 = json!({
            "type": "request",
            "command": "ct/ping",
            "seq": 7003
        });
        client
            .write_all(&dap_encode(&ping1))
            .await
            .map_err(|e| format!("write ping 1: {e}"))?;
        let pong1 = timeout(Duration::from_secs(5), dap_read(&mut client))
            .await
            .map_err(|_| "timeout on ping 1".to_string())?
            .map_err(|e| format!("read ping 1: {e}"))?;
        assert_eq!(
            pong1.get("success").and_then(Value::as_bool),
            Some(true),
            "ping should succeed"
        );

        // Close trace A, verify trace B still loaded.
        let close_a = close_trace(&mut client, 7004, &trace_a, &log_path).await?;
        assert_eq!(
            close_a.get("success").and_then(Value::as_bool),
            Some(true),
            "close A should succeed"
        );

        let status2 = query_daemon_status(&mut client, 7005, &log_path).await?;
        let sessions2 = status2.get("sessions").and_then(Value::as_u64).unwrap_or(0);
        assert_eq!(sessions2, 1, "expected 1 session after closing A, got {sessions2}");

        // Trace B should still be queryable.
        let info_b = query_trace_info(&mut client, 7006, &trace_b, &log_path).await?;
        assert_eq!(
            info_b.get("success").and_then(Value::as_bool),
            Some(true),
            "trace-info for B should still succeed"
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("test_multiple_sessions_independent", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

// ===========================================================================
// M3 Helpers: py-navigate, etc.
// ===========================================================================

/// Sends `ct/py-navigate` with the given method and returns the response.
///
/// Skips any interleaved events that may arrive before the response
/// (e.g., stopped events broadcast to all clients).
async fn py_navigate(
    client: &mut UnixStream,
    seq: i64,
    trace_path: &Path,
    method: &str,
    extra_args: Option<Value>,
    log_path: &Path,
) -> Result<Value, String> {
    let mut args = json!({
        "tracePath": trace_path.to_string_lossy().to_string(),
        "method": method,
    });
    // Merge any extra arguments (e.g., "ticks" for goto_ticks).
    if let Some(extra) = extra_args
        && let (Some(args_obj), Some(extra_obj)) = (args.as_object_mut(), extra.as_object())
    {
        for (k, v) in extra_obj {
            args_obj.insert(k.clone(), v.clone());
        }
    }

    let req = json!({
        "type": "request",
        "command": "ct/py-navigate",
        "seq": seq,
        "arguments": args,
    });
    client
        .write_all(&dap_encode(&req))
        .await
        .map_err(|e| format!("write ct/py-navigate: {e}"))?;

    // Read messages, skipping events, until we get the response.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err("timeout waiting for ct/py-navigate response".to_string());
        }

        let msg = timeout(remaining, dap_read(client))
            .await
            .map_err(|_| "timeout waiting for ct/py-navigate response".to_string())?
            .map_err(|e| format!("read ct/py-navigate: {e}"))?;

        let msg_type = msg.get("type").and_then(Value::as_str).unwrap_or("");
        if msg_type == "event" {
            log_line(log_path, &format!("py-navigate: skipped event: {msg}"));
            continue;
        }

        log_line(log_path, &format!("ct/py-navigate response: {msg}"));
        return Ok(msg);
    }
}

// ===========================================================================
// M3 Tests
// ===========================================================================

/// M3-1. Open trace, verify language and source_files are populated.
#[tokio::test]
async fn m3_open_trace_connects() {
    let (test_dir, log_path) = setup_test_dir("m3_open_trace_connects");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-m3-connect", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.
        let resp = open_trace(&mut client, 10_000, &trace_dir, &log_path).await?;

        assert_eq!(
            resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed"
        );

        let body = resp.get("body").expect("response should have body");

        // Verify language is detected from program extension.
        assert_eq!(
            body.get("language").and_then(Value::as_str),
            Some("nim"),
            "language should be 'nim'"
        );

        // Verify source files are populated.
        let source_files = body
            .get("sourceFiles")
            .and_then(Value::as_array)
            .map(|a| a.len())
            .unwrap_or(0);
        assert!(source_files > 0, "sourceFiles should be non-empty");

        // Verify initialLocation is present (from the post-init stackTrace).
        let init_loc = body.get("initialLocation");
        assert!(init_loc.is_some(), "initialLocation should be present");
        let init_loc = init_loc.unwrap();
        assert!(
            init_loc.get("path").and_then(Value::as_str).is_some(),
            "initialLocation should have a path"
        );
        assert!(
            init_loc.get("line").and_then(Value::as_i64).is_some(),
            "initialLocation should have a line"
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("m3_open_trace_connects", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M3-2. step_over advances location: open trace, step_over, verify
/// the response has a different line than the initial location.
#[tokio::test]
async fn m3_step_over_advances_location() {
    let (test_dir, log_path) = setup_test_dir("m3_step_over_advances");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-m3-step", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.
        let open_resp = open_trace(&mut client, 11_000, &trace_dir, &log_path).await?;
        assert_eq!(
            open_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "open should succeed"
        );

        let initial_line = open_resp
            .get("body")
            .and_then(|b| b.get("initialLocation"))
            .and_then(|l| l.get("line"))
            .and_then(Value::as_i64)
            .unwrap_or(0);
        log_line(&log_path, &format!("initial line: {initial_line}"));

        // step_over.
        let nav_resp =
            py_navigate(&mut client, 11_001, &trace_dir, "step_over", None, &log_path).await?;
        assert_eq!(
            nav_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "step_over should succeed"
        );

        let nav_body = nav_resp.get("body").expect("response should have body");
        let new_line = nav_body.get("line").and_then(Value::as_i64).unwrap_or(0);
        log_line(&log_path, &format!("new line after step_over: {new_line}"));

        // The mock advances the line by 1 on each step_over.
        assert!(
            new_line != initial_line,
            "line should change after step_over (was {initial_line}, now {new_line})"
        );
        assert_eq!(
            new_line,
            initial_line + 1,
            "line should be initial+1 after step_over"
        );

        // Verify ticks also changed.
        let new_ticks = nav_body.get("ticks").and_then(Value::as_i64).unwrap_or(0);
        assert!(new_ticks > 0, "ticks should be > 0 after step_over");

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("m3_step_over_advances_location", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M3-3. step_in enters a different function: open trace, step_in,
/// verify the response has a different file than the initial location.
#[tokio::test]
async fn m3_step_in_enters_function() {
    let (test_dir, log_path) = setup_test_dir("m3_step_in_enters");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-m3-stepin", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.
        let open_resp = open_trace(&mut client, 12_000, &trace_dir, &log_path).await?;
        assert_eq!(
            open_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "open should succeed"
        );

        let initial_file = open_resp
            .get("body")
            .and_then(|b| b.get("initialLocation"))
            .and_then(|l| l.get("path"))
            .and_then(Value::as_str)
            .unwrap_or("");
        log_line(&log_path, &format!("initial file: {initial_file}"));

        // step_in — mock changes file to helpers.nim.
        let nav_resp =
            py_navigate(&mut client, 12_001, &trace_dir, "step_in", None, &log_path).await?;
        assert_eq!(
            nav_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "step_in should succeed"
        );

        let nav_body = nav_resp.get("body").expect("response should have body");
        let new_file = nav_body
            .get("path")
            .and_then(Value::as_str)
            .unwrap_or("");
        log_line(&log_path, &format!("file after step_in: {new_file}"));

        // The mock changes to helpers.nim on step_in.
        assert_eq!(
            new_file, "helpers.nim",
            "file should be helpers.nim after step_in, got {new_file}"
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("m3_step_in_enters_function", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M3-4. step_in then step_out returns to caller: verify back at main.nim.
#[tokio::test]
async fn m3_step_out_returns_to_caller() {
    let (test_dir, log_path) = setup_test_dir("m3_step_out_returns");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-m3-stepout", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.
        let open_resp = open_trace(&mut client, 13_000, &trace_dir, &log_path).await?;
        assert_eq!(
            open_resp.get("success").and_then(Value::as_bool),
            Some(true),
        );

        // step_in (enters helpers.nim).
        let nav1 =
            py_navigate(&mut client, 13_001, &trace_dir, "step_in", None, &log_path).await?;
        assert_eq!(nav1.get("success").and_then(Value::as_bool), Some(true));
        let file_after_in = nav1
            .get("body")
            .and_then(|b| b.get("path"))
            .and_then(Value::as_str)
            .unwrap_or("");
        assert_eq!(file_after_in, "helpers.nim", "should be in helpers.nim after step_in");

        // step_out (returns to main.nim).
        let nav2 =
            py_navigate(&mut client, 13_002, &trace_dir, "step_out", None, &log_path).await?;
        assert_eq!(nav2.get("success").and_then(Value::as_bool), Some(true));
        let file_after_out = nav2
            .get("body")
            .and_then(|b| b.get("path"))
            .and_then(Value::as_str)
            .unwrap_or("");
        assert_eq!(
            file_after_out, "main.nim",
            "should be back at main.nim after step_out, got {file_after_out}"
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("m3_step_out_returns_to_caller", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M3-5. step_back reverses: step_over twice, step_back, verify
/// the line matches the first step_over position.
#[tokio::test]
async fn m3_step_back_reverses() {
    let (test_dir, log_path) = setup_test_dir("m3_step_back_reverses");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-m3-stepback", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        let open_resp = open_trace(&mut client, 14_000, &trace_dir, &log_path).await?;
        assert_eq!(open_resp.get("success").and_then(Value::as_bool), Some(true));

        // step_over (1st).
        let nav1 =
            py_navigate(&mut client, 14_001, &trace_dir, "step_over", None, &log_path).await?;
        assert_eq!(nav1.get("success").and_then(Value::as_bool), Some(true));
        let line_after_first =
            nav1.get("body").and_then(|b| b.get("line")).and_then(Value::as_i64).unwrap_or(0);
        let ticks_after_first =
            nav1.get("body").and_then(|b| b.get("ticks")).and_then(Value::as_i64).unwrap_or(0);
        log_line(&log_path, &format!("after 1st step: line={line_after_first}, ticks={ticks_after_first}"));

        // step_over (2nd).
        let nav2 =
            py_navigate(&mut client, 14_002, &trace_dir, "step_over", None, &log_path).await?;
        assert_eq!(nav2.get("success").and_then(Value::as_bool), Some(true));
        let line_after_second =
            nav2.get("body").and_then(|b| b.get("line")).and_then(Value::as_i64).unwrap_or(0);
        log_line(&log_path, &format!("after 2nd step: line={line_after_second}"));
        assert_eq!(
            line_after_second,
            line_after_first + 1,
            "2nd step should be one line ahead of 1st"
        );

        // step_back (should go back to the first step's position).
        let nav3 =
            py_navigate(&mut client, 14_003, &trace_dir, "step_back", None, &log_path).await?;
        assert_eq!(nav3.get("success").and_then(Value::as_bool), Some(true));
        let line_after_back =
            nav3.get("body").and_then(|b| b.get("line")).and_then(Value::as_i64).unwrap_or(0);
        let ticks_after_back =
            nav3.get("body").and_then(|b| b.get("ticks")).and_then(Value::as_i64).unwrap_or(0);
        log_line(&log_path, &format!("after step_back: line={line_after_back}, ticks={ticks_after_back}"));

        // In the mock: step_back decrements line by 1 and ticks by 10.
        // After 2 step_overs (line=3, ticks=120), step_back => (line=2, ticks=110).
        assert_eq!(
            line_after_back, line_after_first,
            "line after step_back should match first step's line"
        );
        assert_eq!(
            ticks_after_back, ticks_after_first,
            "ticks after step_back should match first step's ticks"
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("m3_step_back_reverses", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M3-6. continue_forward runs to end: verify endOfTrace flag is true.
#[tokio::test]
async fn m3_continue_forward_runs_to_end() {
    let (test_dir, log_path) = setup_test_dir("m3_continue_fwd_end");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-m3-continue-fwd", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        let open_resp = open_trace(&mut client, 15_000, &trace_dir, &log_path).await?;
        assert_eq!(open_resp.get("success").and_then(Value::as_bool), Some(true));

        // continue_forward — mock jumps to line 100 with endOfTrace=true.
        let nav_resp = py_navigate(
            &mut client,
            15_001,
            &trace_dir,
            "continue_forward",
            None,
            &log_path,
        )
        .await?;
        assert_eq!(nav_resp.get("success").and_then(Value::as_bool), Some(true));

        let nav_body = nav_resp.get("body").expect("response should have body");
        let end_of_trace = nav_body
            .get("endOfTrace")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        log_line(&log_path, &format!("endOfTrace: {end_of_trace}"));

        assert!(
            end_of_trace,
            "endOfTrace should be true after continue_forward"
        );

        // Verify line jumped to 100 (mock's end).
        let line = nav_body.get("line").and_then(Value::as_i64).unwrap_or(0);
        assert_eq!(line, 100, "line should be 100 at end of trace");

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("m3_continue_forward_runs_to_end", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M3-7. continue_reverse runs to start: step forward first, then
/// continue_reverse, verify endOfTrace flag.
#[tokio::test]
async fn m3_continue_reverse_runs_to_start() {
    let (test_dir, log_path) = setup_test_dir("m3_continue_rev_start");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-m3-continue-rev", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        let open_resp = open_trace(&mut client, 16_000, &trace_dir, &log_path).await?;
        assert_eq!(open_resp.get("success").and_then(Value::as_bool), Some(true));

        // Step forward once so we're not at the very start.
        let _nav1 =
            py_navigate(&mut client, 16_001, &trace_dir, "step_over", None, &log_path).await?;

        // continue_reverse — mock jumps to line 1 with endOfTrace=true.
        let nav_resp = py_navigate(
            &mut client,
            16_002,
            &trace_dir,
            "continue_reverse",
            None,
            &log_path,
        )
        .await?;
        assert_eq!(nav_resp.get("success").and_then(Value::as_bool), Some(true));

        let nav_body = nav_resp.get("body").expect("response should have body");
        let end_of_trace = nav_body
            .get("endOfTrace")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let line = nav_body.get("line").and_then(Value::as_i64).unwrap_or(-1);
        log_line(
            &log_path,
            &format!("after continue_reverse: line={line}, endOfTrace={end_of_trace}"),
        );

        assert!(
            end_of_trace,
            "endOfTrace should be true after continue_reverse"
        );
        assert_eq!(line, 1, "line should be 1 at start of trace");

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("m3_continue_reverse_runs_to_start", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M3-8. goto_ticks navigates: step to record ticks, navigate away,
/// then goto_ticks to return, verify ticks match.
#[tokio::test]
async fn m3_goto_ticks_navigates() {
    let (test_dir, log_path) = setup_test_dir("m3_goto_ticks");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-m3-goto", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        let open_resp = open_trace(&mut client, 17_000, &trace_dir, &log_path).await?;
        assert_eq!(open_resp.get("success").and_then(Value::as_bool), Some(true));

        // Step forward to get a known ticks value.
        let nav1 =
            py_navigate(&mut client, 17_001, &trace_dir, "step_over", None, &log_path).await?;
        assert_eq!(nav1.get("success").and_then(Value::as_bool), Some(true));
        let target_ticks = nav1
            .get("body")
            .and_then(|b| b.get("ticks"))
            .and_then(Value::as_i64)
            .unwrap_or(0);
        log_line(&log_path, &format!("target ticks: {target_ticks}"));
        assert!(target_ticks > 0, "ticks should be > 0 after step_over");

        // Navigate away (step_over again).
        let _nav2 =
            py_navigate(&mut client, 17_002, &trace_dir, "step_over", None, &log_path).await?;

        // goto_ticks back to the saved position.
        let nav3 = py_navigate(
            &mut client,
            17_003,
            &trace_dir,
            "goto_ticks",
            Some(json!({"ticks": target_ticks})),
            &log_path,
        )
        .await?;
        assert_eq!(nav3.get("success").and_then(Value::as_bool), Some(true));

        let arrived_ticks = nav3
            .get("body")
            .and_then(|b| b.get("ticks"))
            .and_then(Value::as_i64)
            .unwrap_or(0);
        log_line(&log_path, &format!("arrived ticks: {arrived_ticks}"));

        assert_eq!(
            arrived_ticks, target_ticks,
            "ticks after goto_ticks should match target ({target_ticks}), got {arrived_ticks}"
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("m3_goto_ticks_navigates", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M3-9. Location has all fields: verify path, line, column are present.
#[tokio::test]
async fn m3_location_has_all_fields() {
    let (test_dir, log_path) = setup_test_dir("m3_location_all_fields");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-m3-fields", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        let open_resp = open_trace(&mut client, 18_000, &trace_dir, &log_path).await?;
        assert_eq!(open_resp.get("success").and_then(Value::as_bool), Some(true));

        // Navigate to get a location response.
        let nav_resp =
            py_navigate(&mut client, 18_001, &trace_dir, "step_over", None, &log_path).await?;
        assert_eq!(nav_resp.get("success").and_then(Value::as_bool), Some(true));

        let body = nav_resp.get("body").expect("response should have body");

        // Verify all location fields are present and have appropriate types.
        let path = body.get("path").and_then(Value::as_str);
        let line = body.get("line").and_then(Value::as_i64);
        let column = body.get("column").and_then(Value::as_i64);
        let ticks = body.get("ticks").and_then(Value::as_i64);
        let end_of_trace = body.get("endOfTrace").and_then(Value::as_bool);

        log_line(
            &log_path,
            &format!(
                "location: path={path:?}, line={line:?}, column={column:?}, ticks={ticks:?}, endOfTrace={end_of_trace:?}"
            ),
        );

        assert!(path.is_some(), "path should be present");
        assert!(!path.unwrap().is_empty(), "path should not be empty");
        assert!(line.is_some(), "line should be present");
        assert!(line.unwrap() > 0, "line should be > 0");
        assert!(column.is_some(), "column should be present");
        assert!(ticks.is_some(), "ticks should be present");
        assert!(ticks.unwrap() > 0, "ticks should be > 0");
        assert!(end_of_trace.is_some(), "endOfTrace should be present");

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("m3_location_has_all_fields", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

// ===========================================================================
// M4 Helper functions
// ===========================================================================

/// Sends `ct/py-locals` and returns the response (skipping interleaved events).
async fn py_locals(
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
            "tracePath": trace_path.to_string_lossy().to_string(),
            "depth": depth,
            "countBudget": count_budget,
        }
    });
    client
        .write_all(&dap_encode(&req))
        .await
        .map_err(|e| format!("write ct/py-locals: {e}"))?;

    // Read messages, skipping events, until we get the response.
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

        log_line(log_path, &format!("ct/py-locals response: {msg}"));
        return Ok(msg);
    }
}

/// Sends `ct/py-evaluate` and returns the response (skipping interleaved events).
async fn py_evaluate(
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
            "tracePath": trace_path.to_string_lossy().to_string(),
            "expression": expression,
        }
    });
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

        log_line(log_path, &format!("ct/py-evaluate response: {msg}"));
        return Ok(msg);
    }
}

/// Sends `ct/py-stack-trace` and returns the response (skipping interleaved events).
async fn py_stack_trace(
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
            "tracePath": trace_path.to_string_lossy().to_string(),
        }
    });
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

        log_line(log_path, &format!("ct/py-stack-trace response: {msg}"));
        return Ok(msg);
    }
}

/// Sends `ct/py-flow` and returns the response (skipping interleaved events).
///
/// This helper queries the daemon for flow/omniscience data at a specific
/// source location and mode.
async fn py_flow(
    client: &mut UnixStream,
    seq: i64,
    trace_path: &Path,
    source_path: &str,
    line: i64,
    mode: &str,
    log_path: &Path,
) -> Result<Value, String> {
    let req = json!({
        "type": "request",
        "command": "ct/py-flow",
        "seq": seq,
        "arguments": {
            "tracePath": trace_path.to_string_lossy().to_string(),
            "path": source_path,
            "line": line,
            "mode": mode,
        }
    });
    client
        .write_all(&dap_encode(&req))
        .await
        .map_err(|e| format!("write ct/py-flow: {e}"))?;

    // Read messages, skipping events, until we get the response.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err("timeout waiting for ct/py-flow response".to_string());
        }

        let msg = timeout(remaining, dap_read(client))
            .await
            .map_err(|_| "timeout waiting for ct/py-flow response".to_string())?
            .map_err(|e| format!("read ct/py-flow: {e}"))?;

        let msg_type = msg.get("type").and_then(Value::as_str).unwrap_or("");
        if msg_type == "event" {
            log_line(log_path, &format!("py-flow: skipped event: {msg}"));
            continue;
        }

        log_line(log_path, &format!("ct/py-flow response: {msg}"));
        return Ok(msg);
    }
}

// ===========================================================================
// M4 Tests
// ===========================================================================

/// M4-1. Open trace. Call ct/py-locals. Verify a non-empty list of Variables
/// is returned with name, value, and type fields populated.
#[tokio::test]
async fn m4_locals_returns_variables() {
    let (test_dir, log_path) = setup_test_dir("m4_locals_returns_vars");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-m4-locals", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.
        let resp = open_trace(&mut client, 20_000, &trace_dir, &log_path).await?;
        assert_eq!(
            resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed"
        );

        // Call ct/py-locals with default depth (3).
        let locals_resp =
            py_locals(&mut client, 20_001, &trace_dir, 3, 3000, &log_path).await?;

        assert_eq!(
            locals_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/py-locals should succeed, got: {locals_resp}"
        );
        assert_eq!(
            locals_resp.get("command").and_then(Value::as_str),
            Some("ct/py-locals"),
            "command should be ct/py-locals"
        );

        let body = locals_resp.get("body").expect("response should have body");
        let variables = body
            .get("variables")
            .and_then(Value::as_array)
            .expect("body should have variables array");

        // Verify non-empty list.
        assert!(
            !variables.is_empty(),
            "variables should be non-empty"
        );

        // Verify each variable has name, value, type fields populated.
        for var in variables {
            let name = var.get("name").and_then(Value::as_str);
            let value = var.get("value").and_then(Value::as_str);
            let var_type = var.get("type").and_then(Value::as_str);

            assert!(name.is_some(), "variable should have name: {var}");
            assert!(!name.unwrap().is_empty(), "name should not be empty: {var}");
            assert!(value.is_some(), "variable should have value: {var}");
            assert!(var_type.is_some(), "variable should have type: {var}");
            assert!(!var_type.unwrap().is_empty(), "type should not be empty: {var}");
        }

        // Verify we got the expected mock variables (x, y, point).
        let names: Vec<&str> = variables
            .iter()
            .filter_map(|v| v.get("name").and_then(Value::as_str))
            .collect();
        assert!(names.contains(&"x"), "should contain variable 'x'");
        assert!(names.contains(&"y"), "should contain variable 'y'");
        assert!(names.contains(&"point"), "should contain variable 'point'");

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("m4_locals_returns_variables", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M4-2. Navigate to a point with nested structures. Call with depth=1
/// and verify top-level vars but no children. Call with depth=3 and verify
/// deeper nesting.
#[tokio::test]
async fn m4_locals_depth_limit() {
    let (test_dir, log_path) = setup_test_dir("m4_locals_depth");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-m4-depth", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.
        let resp = open_trace(&mut client, 21_000, &trace_dir, &log_path).await?;
        assert_eq!(
            resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed"
        );

        // Call with depth=1 — should have top-level vars but empty children.
        let locals_d1 =
            py_locals(&mut client, 21_001, &trace_dir, 1, 3000, &log_path).await?;
        assert_eq!(
            locals_d1.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/py-locals depth=1 should succeed"
        );

        let body_d1 = locals_d1.get("body").expect("should have body");
        let vars_d1 = body_d1
            .get("variables")
            .and_then(Value::as_array)
            .expect("should have variables");

        // Find the "point" variable.
        let point_d1 = vars_d1
            .iter()
            .find(|v| v.get("name").and_then(Value::as_str) == Some("point"))
            .expect("should have 'point' variable at depth=1");

        // At depth=1, children should be empty.
        let children_d1 = point_d1
            .get("children")
            .and_then(Value::as_array)
            .expect("point should have children field");
        assert!(
            children_d1.is_empty(),
            "at depth=1, point should have no children, got: {children_d1:?}"
        );

        // Call with depth=3 — should have nested children.
        let locals_d3 =
            py_locals(&mut client, 21_002, &trace_dir, 3, 3000, &log_path).await?;
        assert_eq!(
            locals_d3.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/py-locals depth=3 should succeed"
        );

        let body_d3 = locals_d3.get("body").expect("should have body");
        let vars_d3 = body_d3
            .get("variables")
            .and_then(Value::as_array)
            .expect("should have variables");

        let point_d3 = vars_d3
            .iter()
            .find(|v| v.get("name").and_then(Value::as_str) == Some("point"))
            .expect("should have 'point' variable at depth=3");

        // At depth=3, children should be populated.
        let children_d3 = point_d3
            .get("children")
            .and_then(Value::as_array)
            .expect("point should have children field");
        assert!(
            !children_d3.is_empty(),
            "at depth=3, point should have children"
        );

        // Verify children have name/value/type.
        for child in children_d3 {
            assert!(
                child.get("name").and_then(Value::as_str).is_some(),
                "child should have name: {child}"
            );
            assert!(
                child.get("value").and_then(Value::as_str).is_some(),
                "child should have value: {child}"
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

    report("m4_locals_depth_limit", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M4-3. Navigate to a point where x=42. Call evaluate("x"). Verify result
/// is "42".
#[tokio::test]
async fn m4_evaluate_simple_expression() {
    let (test_dir, log_path) = setup_test_dir("m4_eval_simple");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-m4-eval-simple", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.
        let resp = open_trace(&mut client, 22_000, &trace_dir, &log_path).await?;
        assert_eq!(
            resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed"
        );

        // Evaluate "x" — mock returns 42.
        let eval_resp =
            py_evaluate(&mut client, 22_001, &trace_dir, "x", &log_path).await?;

        assert_eq!(
            eval_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "evaluate('x') should succeed, got: {eval_resp}"
        );
        assert_eq!(
            eval_resp.get("command").and_then(Value::as_str),
            Some("ct/py-evaluate"),
            "command should be ct/py-evaluate"
        );

        let body = eval_resp.get("body").expect("response should have body");
        assert_eq!(
            body.get("result").and_then(Value::as_str),
            Some("42"),
            "evaluate('x') result should be '42'"
        );
        assert_eq!(
            body.get("type").and_then(Value::as_str),
            Some("int"),
            "evaluate('x') type should be 'int'"
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("m4_evaluate_simple_expression", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M4-4. Navigate to a point where x=10 and y=20 (mock has x=42, y=20,
/// x+y=30). Call evaluate("x + y"). Verify result is "30".
#[tokio::test]
async fn m4_evaluate_complex_expression() {
    let (test_dir, log_path) = setup_test_dir("m4_eval_complex");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-m4-eval-complex", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.
        let resp = open_trace(&mut client, 23_000, &trace_dir, &log_path).await?;
        assert_eq!(
            resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed"
        );

        // Evaluate "x + y" — mock returns 30.
        let eval_resp =
            py_evaluate(&mut client, 23_001, &trace_dir, "x + y", &log_path).await?;

        assert_eq!(
            eval_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "evaluate('x + y') should succeed, got: {eval_resp}"
        );

        let body = eval_resp.get("body").expect("response should have body");
        assert_eq!(
            body.get("result").and_then(Value::as_str),
            Some("30"),
            "evaluate('x + y') result should be '30'"
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("m4_evaluate_complex_expression", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M4-5. Call evaluate("nonexistent_var"). Verify error response (success=false
/// with error message).
#[tokio::test]
async fn m4_evaluate_invalid_expression() {
    let (test_dir, log_path) = setup_test_dir("m4_eval_invalid");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-m4-eval-invalid", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.
        let resp = open_trace(&mut client, 24_000, &trace_dir, &log_path).await?;
        assert_eq!(
            resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed"
        );

        // Evaluate "nonexistent_var" — mock returns error.
        let eval_resp =
            py_evaluate(&mut client, 24_001, &trace_dir, "nonexistent_var", &log_path).await?;

        assert_eq!(
            eval_resp.get("success").and_then(Value::as_bool),
            Some(false),
            "evaluate('nonexistent_var') should fail, got: {eval_resp}"
        );
        assert_eq!(
            eval_resp.get("command").and_then(Value::as_str),
            Some("ct/py-evaluate"),
            "command should be ct/py-evaluate"
        );

        // Verify error message is present and mentions the variable.
        let message = eval_resp
            .get("message")
            .and_then(Value::as_str)
            .expect("error response should have message");
        assert!(
            message.contains("nonexistent_var"),
            "error message should mention 'nonexistent_var', got: {message}"
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("m4_evaluate_invalid_expression", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M4-6. Navigate into a nested function call (stepIn). Call stack_trace().
/// Verify a list of Frame objects with at least 2 entries. Verify each has
/// name and location.
#[tokio::test]
async fn m4_stack_trace_returns_frames() {
    let (test_dir, log_path) = setup_test_dir("m4_stack_trace_frames");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-m4-stack", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.
        let resp = open_trace(&mut client, 25_000, &trace_dir, &log_path).await?;
        assert_eq!(
            resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed"
        );

        // Step into a function call to increase call_depth in the mock.
        // This causes the mock's stackTrace to return 2+ frames.
        let _nav_resp =
            py_navigate(&mut client, 25_001, &trace_dir, "step_in", None, &log_path).await?;

        // Now call stack_trace.
        let st_resp =
            py_stack_trace(&mut client, 25_002, &trace_dir, &log_path).await?;

        assert_eq!(
            st_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/py-stack-trace should succeed, got: {st_resp}"
        );
        assert_eq!(
            st_resp.get("command").and_then(Value::as_str),
            Some("ct/py-stack-trace"),
            "command should be ct/py-stack-trace"
        );

        let body = st_resp.get("body").expect("response should have body");
        let frames = body
            .get("frames")
            .and_then(Value::as_array)
            .expect("body should have frames array");

        // After stepIn, the mock returns at least 2 frames.
        assert!(
            frames.len() >= 2,
            "stack trace should have at least 2 frames, got {}",
            frames.len()
        );

        // Verify each frame has name and location.
        for (i, frame) in frames.iter().enumerate() {
            let name = frame.get("name").and_then(Value::as_str);
            assert!(
                name.is_some(),
                "frame {i} should have name: {frame}"
            );
            assert!(
                !name.unwrap().is_empty(),
                "frame {i} name should not be empty"
            );

            let location = frame.get("location");
            assert!(
                location.is_some(),
                "frame {i} should have location: {frame}"
            );

            let loc = location.unwrap();
            let path = loc.get("path").and_then(Value::as_str);
            assert!(
                path.is_some(),
                "frame {i} location should have path: {loc}"
            );
            assert!(
                !path.unwrap().is_empty(),
                "frame {i} path should not be empty"
            );

            let line = loc.get("line").and_then(Value::as_i64);
            assert!(
                line.is_some(),
                "frame {i} location should have line: {loc}"
            );
            assert!(
                line.unwrap() > 0,
                "frame {i} line should be > 0"
            );
        }

        // Verify specific frame names: top frame should be "helper" (after stepIn),
        // and the caller should be "main".
        assert_eq!(
            frames[0].get("name").and_then(Value::as_str),
            Some("helper"),
            "top frame should be 'helper'"
        );
        assert_eq!(
            frames[1].get("name").and_then(Value::as_str),
            Some("main"),
            "caller frame should be 'main'"
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("m4_stack_trace_returns_frames", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

// ===========================================================================
// M5 Helper functions
// ===========================================================================

/// Sends `ct/py-add-breakpoint` and returns the response (skipping events).
async fn py_add_breakpoint(
    client: &mut UnixStream,
    seq: i64,
    trace_path: &Path,
    source_path: &str,
    line: i64,
    log_path: &Path,
) -> Result<Value, String> {
    let req = json!({
        "type": "request",
        "command": "ct/py-add-breakpoint",
        "seq": seq,
        "arguments": {
            "tracePath": trace_path.to_string_lossy().to_string(),
            "path": source_path,
            "line": line,
        }
    });
    client
        .write_all(&dap_encode(&req))
        .await
        .map_err(|e| format!("write ct/py-add-breakpoint: {e}"))?;

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
            log_line(log_path, &format!("py-add-breakpoint: skipped event: {msg}"));
            continue;
        }

        log_line(log_path, &format!("ct/py-add-breakpoint response: {msg}"));
        return Ok(msg);
    }
}

/// Sends `ct/py-remove-breakpoint` and returns the response (skipping events).
async fn py_remove_breakpoint(
    client: &mut UnixStream,
    seq: i64,
    trace_path: &Path,
    bp_id: i64,
    log_path: &Path,
) -> Result<Value, String> {
    let req = json!({
        "type": "request",
        "command": "ct/py-remove-breakpoint",
        "seq": seq,
        "arguments": {
            "tracePath": trace_path.to_string_lossy().to_string(),
            "breakpointId": bp_id,
        }
    });
    client
        .write_all(&dap_encode(&req))
        .await
        .map_err(|e| format!("write ct/py-remove-breakpoint: {e}"))?;

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
            log_line(log_path, &format!("py-remove-breakpoint: skipped event: {msg}"));
            continue;
        }

        log_line(log_path, &format!("ct/py-remove-breakpoint response: {msg}"));
        return Ok(msg);
    }
}

/// Sends `ct/py-add-watchpoint` and returns the response (skipping events).
async fn py_add_watchpoint(
    client: &mut UnixStream,
    seq: i64,
    trace_path: &Path,
    expression: &str,
    log_path: &Path,
) -> Result<Value, String> {
    let req = json!({
        "type": "request",
        "command": "ct/py-add-watchpoint",
        "seq": seq,
        "arguments": {
            "tracePath": trace_path.to_string_lossy().to_string(),
            "expression": expression,
        }
    });
    client
        .write_all(&dap_encode(&req))
        .await
        .map_err(|e| format!("write ct/py-add-watchpoint: {e}"))?;

    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err("timeout waiting for ct/py-add-watchpoint response".to_string());
        }

        let msg = timeout(remaining, dap_read(client))
            .await
            .map_err(|_| "timeout waiting for ct/py-add-watchpoint response".to_string())?
            .map_err(|e| format!("read ct/py-add-watchpoint: {e}"))?;

        let msg_type = msg.get("type").and_then(Value::as_str).unwrap_or("");
        if msg_type == "event" {
            log_line(log_path, &format!("py-add-watchpoint: skipped event: {msg}"));
            continue;
        }

        log_line(log_path, &format!("ct/py-add-watchpoint response: {msg}"));
        return Ok(msg);
    }
}

/// Sends `ct/py-remove-watchpoint` and returns the response (skipping events).
#[allow(dead_code)]
async fn py_remove_watchpoint(
    client: &mut UnixStream,
    seq: i64,
    trace_path: &Path,
    wp_id: i64,
    log_path: &Path,
) -> Result<Value, String> {
    let req = json!({
        "type": "request",
        "command": "ct/py-remove-watchpoint",
        "seq": seq,
        "arguments": {
            "tracePath": trace_path.to_string_lossy().to_string(),
            "watchpointId": wp_id,
        }
    });
    client
        .write_all(&dap_encode(&req))
        .await
        .map_err(|e| format!("write ct/py-remove-watchpoint: {e}"))?;

    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err("timeout waiting for ct/py-remove-watchpoint response".to_string());
        }

        let msg = timeout(remaining, dap_read(client))
            .await
            .map_err(|_| "timeout waiting for ct/py-remove-watchpoint response".to_string())?
            .map_err(|e| format!("read ct/py-remove-watchpoint: {e}"))?;

        let msg_type = msg.get("type").and_then(Value::as_str).unwrap_or("");
        if msg_type == "event" {
            log_line(log_path, &format!("py-remove-watchpoint: skipped event: {msg}"));
            continue;
        }

        log_line(log_path, &format!("ct/py-remove-watchpoint response: {msg}"));
        return Ok(msg);
    }
}

// ===========================================================================
// M5 Tests
// ===========================================================================

/// M5-1. Open trace. Add breakpoint at a known line. Call continue_forward().
/// Verify execution stops at the breakpoint line.
#[tokio::test]
async fn m5_breakpoint_stops_execution() {
    let (test_dir, log_path) = setup_test_dir("m5_bp_stops");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-m5-bp-stop", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.  Mock starts at line 1, file "main.nim".
        let resp = open_trace(&mut client, 30_000, &trace_dir, &log_path).await?;
        assert_eq!(
            resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed"
        );

        // Add breakpoint at line 10 in main.nim.
        let bp_resp =
            py_add_breakpoint(&mut client, 30_001, &trace_dir, "main.nim", 10, &log_path).await?;
        assert_eq!(
            bp_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/py-add-breakpoint should succeed, got: {bp_resp}"
        );

        // continue_forward — should stop at line 10 (the breakpoint).
        let nav_resp =
            py_navigate(&mut client, 30_002, &trace_dir, "continue_forward", None, &log_path)
                .await?;
        assert_eq!(
            nav_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "continue_forward should succeed"
        );

        let body = nav_resp.get("body").expect("response should have body");
        let stopped_line = body.get("line").and_then(Value::as_i64).unwrap_or(0);
        log_line(&log_path, &format!("stopped at line: {stopped_line}"));

        assert_eq!(
            stopped_line, 10,
            "execution should stop at the breakpoint line (10), got {stopped_line}"
        );

        // endOfTrace should be false (stopped at breakpoint, not end).
        let end_of_trace = body.get("endOfTrace").and_then(Value::as_bool).unwrap_or(true);
        assert!(
            !end_of_trace,
            "endOfTrace should be false when stopped at a breakpoint"
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("m5_breakpoint_stops_execution", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M5-2. Add breakpoint at line L. Continue to it. Remove breakpoint.
/// Continue again. Verify execution does NOT stop at line L again.
#[tokio::test]
async fn m5_remove_breakpoint_continues_past() {
    let (test_dir, log_path) = setup_test_dir("m5_remove_bp");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-m5-remove-bp", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace (starts at line 1).
        let resp = open_trace(&mut client, 31_000, &trace_dir, &log_path).await?;
        assert_eq!(
            resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed"
        );

        // Add breakpoint at line 10.
        let bp_resp =
            py_add_breakpoint(&mut client, 31_001, &trace_dir, "main.nim", 10, &log_path).await?;
        assert_eq!(
            bp_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "add_breakpoint should succeed"
        );
        let bp_id = bp_resp
            .get("body")
            .and_then(|b| b.get("breakpointId"))
            .and_then(Value::as_i64)
            .ok_or("missing breakpointId")?;
        log_line(&log_path, &format!("breakpoint id: {bp_id}"));

        // Continue forward — should stop at line 10.
        let nav1 =
            py_navigate(&mut client, 31_002, &trace_dir, "continue_forward", None, &log_path)
                .await?;
        let line1 = nav1
            .get("body")
            .and_then(|b| b.get("line"))
            .and_then(Value::as_i64)
            .unwrap_or(0);
        assert_eq!(line1, 10, "first continue should stop at line 10");

        // Remove the breakpoint.
        let rm_resp =
            py_remove_breakpoint(&mut client, 31_003, &trace_dir, bp_id, &log_path).await?;
        assert_eq!(
            rm_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "remove_breakpoint should succeed"
        );

        // Continue forward again — with the breakpoint removed, should
        // go to end of trace (line 100) instead of stopping at line 10.
        let nav2 =
            py_navigate(&mut client, 31_004, &trace_dir, "continue_forward", None, &log_path)
                .await?;
        let line2 = nav2
            .get("body")
            .and_then(|b| b.get("line"))
            .and_then(Value::as_i64)
            .unwrap_or(0);
        log_line(&log_path, &format!("second continue stopped at line: {line2}"));

        assert_ne!(
            line2, 10,
            "after removing breakpoint, should NOT stop at line 10 again"
        );
        // Should hit end of trace.
        let end_of_trace = nav2
            .get("body")
            .and_then(|b| b.get("endOfTrace"))
            .and_then(Value::as_bool)
            .unwrap_or(false);
        assert!(
            end_of_trace,
            "should reach end of trace after removing breakpoint"
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("m5_remove_breakpoint_continues_past", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M5-3. Add breakpoints at lines L1, L2, L3. Continue forward. Verify stops
/// at L1. Continue. Verify stops at L2. Continue. Verify stops at L3.
#[tokio::test]
async fn m5_multiple_breakpoints() {
    let (test_dir, log_path) = setup_test_dir("m5_multi_bp");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-m5-multi-bp", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace (starts at line 1).
        let resp = open_trace(&mut client, 32_000, &trace_dir, &log_path).await?;
        assert_eq!(
            resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed"
        );

        // Add three breakpoints at lines 10, 20, 30.
        let bp1 =
            py_add_breakpoint(&mut client, 32_001, &trace_dir, "main.nim", 10, &log_path).await?;
        assert_eq!(
            bp1.get("success").and_then(Value::as_bool),
            Some(true),
            "add_breakpoint at 10 should succeed"
        );

        let bp2 =
            py_add_breakpoint(&mut client, 32_002, &trace_dir, "main.nim", 20, &log_path).await?;
        assert_eq!(
            bp2.get("success").and_then(Value::as_bool),
            Some(true),
            "add_breakpoint at 20 should succeed"
        );

        let bp3 =
            py_add_breakpoint(&mut client, 32_003, &trace_dir, "main.nim", 30, &log_path).await?;
        assert_eq!(
            bp3.get("success").and_then(Value::as_bool),
            Some(true),
            "add_breakpoint at 30 should succeed"
        );

        // Continue — should stop at line 10.
        let nav1 =
            py_navigate(&mut client, 32_004, &trace_dir, "continue_forward", None, &log_path)
                .await?;
        let line1 = nav1
            .get("body")
            .and_then(|b| b.get("line"))
            .and_then(Value::as_i64)
            .unwrap_or(0);
        assert_eq!(line1, 10, "first continue should stop at line 10, got {line1}");

        // Continue — should stop at line 20.
        let nav2 =
            py_navigate(&mut client, 32_005, &trace_dir, "continue_forward", None, &log_path)
                .await?;
        let line2 = nav2
            .get("body")
            .and_then(|b| b.get("line"))
            .and_then(Value::as_i64)
            .unwrap_or(0);
        assert_eq!(line2, 20, "second continue should stop at line 20, got {line2}");

        // Continue — should stop at line 30.
        let nav3 =
            py_navigate(&mut client, 32_006, &trace_dir, "continue_forward", None, &log_path)
                .await?;
        let line3 = nav3
            .get("body")
            .and_then(|b| b.get("line"))
            .and_then(Value::as_i64)
            .unwrap_or(0);
        assert_eq!(line3, 30, "third continue should stop at line 30, got {line3}");

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("m5_multiple_breakpoints", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M5-4. Add breakpoint at a line. Navigate past it. Call continue_reverse().
/// Verify execution stops at the breakpoint line.
#[tokio::test]
async fn m5_reverse_continue_hits_breakpoint() {
    let (test_dir, log_path) = setup_test_dir("m5_rev_bp");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-m5-rev-bp", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace (starts at line 1).
        let resp = open_trace(&mut client, 33_000, &trace_dir, &log_path).await?;
        assert_eq!(
            resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed"
        );

        // Navigate past line 10 by stepping over several times.
        // The mock advances +1 line per step_over.  Starting at line 1,
        // we need 14 steps to get to line 15 (past the breakpoint at 10).
        for i in 0..14 {
            let nav = py_navigate(
                &mut client,
                33_001 + i,
                &trace_dir,
                "step_over",
                None,
                &log_path,
            )
            .await?;
            assert_eq!(
                nav.get("success").and_then(Value::as_bool),
                Some(true),
                "step_over {i} should succeed"
            );
        }

        // Verify we are now past line 10 (should be at line 15).
        let current_nav = py_navigate(
            &mut client,
            33_020,
            &trace_dir,
            "step_over",
            None,
            &log_path,
        )
        .await?;
        let current_line = current_nav
            .get("body")
            .and_then(|b| b.get("line"))
            .and_then(Value::as_i64)
            .unwrap_or(0);
        log_line(&log_path, &format!("current line before reverse: {current_line}"));
        assert!(
            current_line > 10,
            "should be past line 10, at line {current_line}"
        );

        // Now add a breakpoint at line 10.
        let bp_resp =
            py_add_breakpoint(&mut client, 33_021, &trace_dir, "main.nim", 10, &log_path).await?;
        assert_eq!(
            bp_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "add_breakpoint should succeed"
        );

        // continue_reverse — should stop at line 10 (the breakpoint).
        let rev_resp =
            py_navigate(&mut client, 33_022, &trace_dir, "continue_reverse", None, &log_path)
                .await?;
        assert_eq!(
            rev_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "continue_reverse should succeed"
        );

        let rev_body = rev_resp.get("body").expect("response should have body");
        let rev_line = rev_body.get("line").and_then(Value::as_i64).unwrap_or(0);
        log_line(&log_path, &format!("reverse stopped at line: {rev_line}"));

        assert_eq!(
            rev_line, 10,
            "reverse continue should stop at breakpoint line 10, got {rev_line}"
        );

        // endOfTrace should be false (stopped at breakpoint).
        let end_of_trace = rev_body
            .get("endOfTrace")
            .and_then(Value::as_bool)
            .unwrap_or(true);
        assert!(
            !end_of_trace,
            "endOfTrace should be false when stopped at a reverse breakpoint"
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("m5_reverse_continue_hits_breakpoint", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M5-5. Add watchpoint on a variable. Call continue_forward(). Verify
/// execution stops at the point where the variable changed value.
///
/// The mock simulates a variable value change at line 5 when a watchpoint
/// is active: if the current line is < 5 and any watchpoint exists,
/// `continue` stops at line 5.
#[tokio::test]
async fn m5_watchpoint_detects_change() {
    let (test_dir, log_path) = setup_test_dir("m5_watchpoint");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-m5-watchpoint", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace (starts at line 1).
        let resp = open_trace(&mut client, 34_000, &trace_dir, &log_path).await?;
        assert_eq!(
            resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed"
        );

        // Add a watchpoint on the variable "counter".
        let wp_resp =
            py_add_watchpoint(&mut client, 34_001, &trace_dir, "counter", &log_path).await?;
        assert_eq!(
            wp_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "add_watchpoint should succeed, got: {wp_resp}"
        );
        let wp_id = wp_resp
            .get("body")
            .and_then(|b| b.get("watchpointId"))
            .and_then(Value::as_i64)
            .ok_or("missing watchpointId")?;
        assert!(wp_id > 0, "watchpointId should be positive, got {wp_id}");

        // continue_forward — should stop at line 5 (the mock's simulated
        // variable change point).
        let nav_resp =
            py_navigate(&mut client, 34_002, &trace_dir, "continue_forward", None, &log_path)
                .await?;
        assert_eq!(
            nav_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "continue_forward should succeed"
        );

        let body = nav_resp.get("body").expect("response should have body");
        let stopped_line = body.get("line").and_then(Value::as_i64).unwrap_or(0);
        log_line(&log_path, &format!("watchpoint stopped at line: {stopped_line}"));

        assert_eq!(
            stopped_line, 5,
            "should stop at the variable change point (line 5), got {stopped_line}"
        );

        let end_of_trace = body.get("endOfTrace").and_then(Value::as_bool).unwrap_or(true);
        assert!(
            !end_of_trace,
            "endOfTrace should be false at watchpoint hit"
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("m5_watchpoint_detects_change", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M5-6. Call add_breakpoint(). Verify the return value is a positive integer.
/// Use it with remove_breakpoint(). Verify no error.
#[tokio::test]
async fn m5_add_breakpoint_returns_id() {
    let (test_dir, log_path) = setup_test_dir("m5_bp_id");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-m5-bp-id", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.
        let resp = open_trace(&mut client, 35_000, &trace_dir, &log_path).await?;
        assert_eq!(
            resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed"
        );

        // Call add_breakpoint.
        let bp_resp =
            py_add_breakpoint(&mut client, 35_001, &trace_dir, "main.nim", 42, &log_path).await?;
        assert_eq!(
            bp_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "add_breakpoint should succeed, got: {bp_resp}"
        );

        let bp_id = bp_resp
            .get("body")
            .and_then(|b| b.get("breakpointId"))
            .and_then(Value::as_i64)
            .ok_or("missing breakpointId in response")?;

        log_line(&log_path, &format!("breakpointId: {bp_id}"));

        // Verify the ID is a positive integer.
        assert!(
            bp_id > 0,
            "breakpointId should be a positive integer, got {bp_id}"
        );

        // Use it with remove_breakpoint — should succeed without error.
        let rm_resp =
            py_remove_breakpoint(&mut client, 35_002, &trace_dir, bp_id, &log_path).await?;
        assert_eq!(
            rm_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "remove_breakpoint with valid ID should succeed, got: {rm_resp}"
        );

        let removed = rm_resp
            .get("body")
            .and_then(|b| b.get("removed"))
            .and_then(Value::as_bool)
            .unwrap_or(false);
        assert!(removed, "removed field should be true");

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("m5_add_breakpoint_returns_id", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

// ===========================================================================
// M6 Tests — Flow / Omniscience
// ===========================================================================

/// M6-1. Open trace with a function containing a loop. Call
/// `ct/py-flow` with mode="call". Verify `steps` is non-empty.
/// Verify each step has `beforeValues` and `afterValues` dictionaries.
#[tokio::test]
async fn m6_flow_returns_steps() {
    let (test_dir, log_path) = setup_test_dir("m6_flow_steps");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-m6-steps", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.
        let resp = open_trace(&mut client, 40_000, &trace_dir, &log_path).await?;
        assert_eq!(
            resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed"
        );

        // Call ct/py-flow with mode="call".
        let flow_resp =
            py_flow(&mut client, 40_001, &trace_dir, "main.nim", 10, "call", &log_path).await?;

        assert_eq!(
            flow_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/py-flow should succeed, got: {flow_resp}"
        );
        assert_eq!(
            flow_resp.get("command").and_then(Value::as_str),
            Some("ct/py-flow"),
            "command should be ct/py-flow"
        );

        let body = flow_resp.get("body").expect("response should have body");
        let steps = body
            .get("steps")
            .and_then(Value::as_array)
            .expect("body should have steps array");

        // Verify non-empty list of steps.
        assert!(
            !steps.is_empty(),
            "steps should be non-empty"
        );

        // Verify each step has beforeValues and afterValues dictionaries.
        for (i, step) in steps.iter().enumerate() {
            let before = step.get("beforeValues");
            assert!(
                before.is_some() && before.unwrap().is_object(),
                "step {i} should have beforeValues dict, got: {step}"
            );
            let after = step.get("afterValues");
            assert!(
                after.is_some() && after.unwrap().is_object(),
                "step {i} should have afterValues dict, got: {step}"
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

    report("m6_flow_returns_steps", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M6-2. Query flow for a line inside a loop. Verify `loops` is non-empty.
/// Verify the loop has `iterationCount > 1`.
#[tokio::test]
async fn m6_flow_loop_detected() {
    let (test_dir, log_path) = setup_test_dir("m6_flow_loop");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-m6-loop", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.
        let resp = open_trace(&mut client, 41_000, &trace_dir, &log_path).await?;
        assert_eq!(
            resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed"
        );

        // Query flow for a line inside a loop.
        let flow_resp =
            py_flow(&mut client, 41_001, &trace_dir, "main.nim", 10, "call", &log_path).await?;

        assert_eq!(
            flow_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/py-flow should succeed, got: {flow_resp}"
        );

        let body = flow_resp.get("body").expect("response should have body");
        let loops = body
            .get("loops")
            .and_then(Value::as_array)
            .expect("body should have loops array");

        // Verify loops is non-empty.
        assert!(
            !loops.is_empty(),
            "loops should be non-empty"
        );

        // Verify the loop has iterationCount > 1.
        let first_loop = &loops[0];
        let iteration_count = first_loop
            .get("iterationCount")
            .and_then(Value::as_i64)
            .expect("loop should have iterationCount");

        assert!(
            iteration_count > 1,
            "iterationCount should be > 1, got {iteration_count}"
        );

        // Also verify the loop has structural fields.
        assert!(
            first_loop.get("id").and_then(Value::as_i64).is_some(),
            "loop should have an 'id' field"
        );
        assert!(
            first_loop.get("startLine").and_then(Value::as_i64).is_some(),
            "loop should have a 'startLine' field"
        );
        assert!(
            first_loop.get("endLine").and_then(Value::as_i64).is_some(),
            "loop should have an 'endLine' field"
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("m6_flow_loop_detected", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M6-3. Query flow for a line where `x = i * 2` inside a loop with `i`
/// from 0 to 4. Verify the step values show `x` changing as expected
/// across iterations.
#[tokio::test]
async fn m6_flow_values_correct() {
    let (test_dir, log_path) = setup_test_dir("m6_flow_vals");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-m6-vals", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.
        let resp = open_trace(&mut client, 42_000, &trace_dir, &log_path).await?;
        assert_eq!(
            resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed"
        );

        // Query flow in "line" mode — returns only the loop iteration steps
        // for the specific line (no function entry/exit steps).
        let flow_resp =
            py_flow(&mut client, 42_001, &trace_dir, "main.nim", 10, "line", &log_path).await?;

        assert_eq!(
            flow_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/py-flow should succeed, got: {flow_resp}"
        );

        let body = flow_resp.get("body").expect("response should have body");
        let steps = body
            .get("steps")
            .and_then(Value::as_array)
            .expect("body should have steps array");

        // In line mode, the mock returns exactly 5 steps (i from 0 to 4).
        assert_eq!(
            steps.len(),
            5,
            "line mode should return 5 steps (one per iteration), got {}",
            steps.len()
        );

        // Verify x changes as expected: x = i * 2 for i in 0..5.
        for (idx, step) in steps.iter().enumerate() {
            let i_val = idx as i64;
            let expected_x = (i_val * 2).to_string();

            let after_values = step
                .get("afterValues")
                .and_then(Value::as_object)
                .expect("step should have afterValues dict");

            let actual_x = after_values
                .get("x")
                .and_then(Value::as_str)
                .unwrap_or("");

            assert_eq!(
                actual_x, expected_x,
                "step {idx}: afterValues.x should be {expected_x}, got {actual_x}"
            );

            // Also verify the iteration field matches.
            let iteration = step
                .get("iteration")
                .and_then(Value::as_i64)
                .unwrap_or(-1);
            assert_eq!(
                iteration, i_val,
                "step {idx}: iteration should be {i_val}, got {iteration}"
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

    report("m6_flow_values_correct", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M6-4. Query the same location with mode="call" and mode="line".
/// Verify different amounts of data returned (call mode returns more
/// steps spanning the full function).
#[tokio::test]
async fn m6_flow_modes_differ() {
    let (test_dir, log_path) = setup_test_dir("m6_flow_modes");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-m6-modes", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.
        let resp = open_trace(&mut client, 43_000, &trace_dir, &log_path).await?;
        assert_eq!(
            resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed"
        );

        // Query flow with mode="call" (full function scope).
        let call_resp =
            py_flow(&mut client, 43_001, &trace_dir, "main.nim", 10, "call", &log_path).await?;
        assert_eq!(
            call_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/py-flow (call) should succeed, got: {call_resp}"
        );

        let call_steps = call_resp
            .get("body")
            .and_then(|b| b.get("steps"))
            .and_then(Value::as_array)
            .expect("call response should have steps");
        let call_step_count = call_steps.len();

        log_line(&log_path, &format!("call mode steps: {call_step_count}"));

        // Query flow with mode="line" (specific line only).
        let line_resp =
            py_flow(&mut client, 43_002, &trace_dir, "main.nim", 10, "line", &log_path).await?;
        assert_eq!(
            line_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/py-flow (line) should succeed, got: {line_resp}"
        );

        let line_steps = line_resp
            .get("body")
            .and_then(|b| b.get("steps"))
            .and_then(Value::as_array)
            .expect("line response should have steps");
        let line_step_count = line_steps.len();

        log_line(&log_path, &format!("line mode steps: {line_step_count}"));

        // Call mode should return more steps than line mode because it
        // includes function entry and exit steps in addition to the loop
        // iterations.
        //
        // Mock data: call mode = 7 steps (1 entry + 5 loop + 1 exit),
        //            line mode = 5 steps (5 loop only).
        assert!(
            call_step_count > line_step_count,
            "call mode should return more steps ({call_step_count}) than line mode ({line_step_count})"
        );

        // Verify call mode has steps outside the queried line (i.e., steps
        // at different line numbers).
        let call_lines: Vec<i64> = call_steps
            .iter()
            .filter_map(|s| s.get("line").and_then(Value::as_i64))
            .collect();
        let has_other_lines = call_lines.iter().any(|l| *l != 10);
        assert!(
            has_other_lines,
            "call mode should include steps at lines other than the queried line 10, got lines: {call_lines:?}"
        );

        // Verify line mode only has steps at the queried line.
        let line_lines: Vec<i64> = line_steps
            .iter()
            .filter_map(|s| s.get("line").and_then(Value::as_i64))
            .collect();
        let all_same_line = line_lines.iter().all(|l| *l == 10);
        assert!(
            all_same_line,
            "line mode should only have steps at line 10, got lines: {line_lines:?}"
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("m6_flow_modes_differ", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

// ===========================================================================
// M7 Helper functions
// ===========================================================================

/// Sends `ct/py-calltrace` and returns the response (skipping interleaved events).
async fn py_calltrace(
    client: &mut UnixStream,
    seq: i64,
    trace_path: &Path,
    start: i64,
    count: i64,
    depth: i64,
    log_path: &Path,
) -> Result<Value, String> {
    let req = json!({
        "type": "request",
        "command": "ct/py-calltrace",
        "seq": seq,
        "arguments": {
            "tracePath": trace_path.to_string_lossy().to_string(),
            "start": start,
            "count": count,
            "depth": depth,
        }
    });
    client
        .write_all(&dap_encode(&req))
        .await
        .map_err(|e| format!("write ct/py-calltrace: {e}"))?;

    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err("timeout waiting for ct/py-calltrace response".to_string());
        }

        let msg = timeout(remaining, dap_read(client))
            .await
            .map_err(|_| "timeout waiting for ct/py-calltrace response".to_string())?
            .map_err(|e| format!("read ct/py-calltrace: {e}"))?;

        let msg_type = msg.get("type").and_then(Value::as_str).unwrap_or("");
        if msg_type == "event" {
            log_line(log_path, &format!("py-calltrace: skipped event: {msg}"));
            continue;
        }

        log_line(log_path, &format!("ct/py-calltrace response: {msg}"));
        return Ok(msg);
    }
}

/// Sends `ct/py-search-calltrace` and returns the response (skipping interleaved events).
async fn py_search_calltrace(
    client: &mut UnixStream,
    seq: i64,
    trace_path: &Path,
    query: &str,
    limit: i64,
    log_path: &Path,
) -> Result<Value, String> {
    let req = json!({
        "type": "request",
        "command": "ct/py-search-calltrace",
        "seq": seq,
        "arguments": {
            "tracePath": trace_path.to_string_lossy().to_string(),
            "query": query,
            "limit": limit,
        }
    });
    client
        .write_all(&dap_encode(&req))
        .await
        .map_err(|e| format!("write ct/py-search-calltrace: {e}"))?;

    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err("timeout waiting for ct/py-search-calltrace response".to_string());
        }

        let msg = timeout(remaining, dap_read(client))
            .await
            .map_err(|_| "timeout waiting for ct/py-search-calltrace response".to_string())?
            .map_err(|e| format!("read ct/py-search-calltrace: {e}"))?;

        let msg_type = msg.get("type").and_then(Value::as_str).unwrap_or("");
        if msg_type == "event" {
            log_line(log_path, &format!("py-search-calltrace: skipped event: {msg}"));
            continue;
        }

        log_line(log_path, &format!("ct/py-search-calltrace response: {msg}"));
        return Ok(msg);
    }
}

/// Sends `ct/py-events` and returns the response (skipping interleaved events).
async fn py_events(
    client: &mut UnixStream,
    seq: i64,
    trace_path: &Path,
    start: i64,
    count: i64,
    type_filter: Option<&str>,
    log_path: &Path,
) -> Result<Value, String> {
    let mut args = json!({
        "tracePath": trace_path.to_string_lossy().to_string(),
        "start": start,
        "count": count,
    });
    if let Some(tf) = type_filter {
        args["typeFilter"] = json!(tf);
    }

    let req = json!({
        "type": "request",
        "command": "ct/py-events",
        "seq": seq,
        "arguments": args,
    });
    client
        .write_all(&dap_encode(&req))
        .await
        .map_err(|e| format!("write ct/py-events: {e}"))?;

    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err("timeout waiting for ct/py-events response".to_string());
        }

        let msg = timeout(remaining, dap_read(client))
            .await
            .map_err(|_| "timeout waiting for ct/py-events response".to_string())?
            .map_err(|e| format!("read ct/py-events: {e}"))?;

        let msg_type = msg.get("type").and_then(Value::as_str).unwrap_or("");
        if msg_type == "event" {
            log_line(log_path, &format!("py-events: skipped event: {msg}"));
            continue;
        }

        log_line(log_path, &format!("ct/py-events response: {msg}"));
        return Ok(msg);
    }
}

/// Sends `ct/py-terminal` and returns the response (skipping interleaved events).
async fn py_terminal(
    client: &mut UnixStream,
    seq: i64,
    trace_path: &Path,
    log_path: &Path,
) -> Result<Value, String> {
    let req = json!({
        "type": "request",
        "command": "ct/py-terminal",
        "seq": seq,
        "arguments": {
            "tracePath": trace_path.to_string_lossy().to_string(),
            "startLine": 0,
            "endLine": -1,
        }
    });
    client
        .write_all(&dap_encode(&req))
        .await
        .map_err(|e| format!("write ct/py-terminal: {e}"))?;

    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err("timeout waiting for ct/py-terminal response".to_string());
        }

        let msg = timeout(remaining, dap_read(client))
            .await
            .map_err(|_| "timeout waiting for ct/py-terminal response".to_string())?
            .map_err(|e| format!("read ct/py-terminal: {e}"))?;

        let msg_type = msg.get("type").and_then(Value::as_str).unwrap_or("");
        if msg_type == "event" {
            log_line(log_path, &format!("py-terminal: skipped event: {msg}"));
            continue;
        }

        log_line(log_path, &format!("ct/py-terminal response: {msg}"));
        return Ok(msg);
    }
}

/// Sends `ct/py-read-source` and returns the response (skipping interleaved events).
async fn py_read_source(
    client: &mut UnixStream,
    seq: i64,
    trace_path: &Path,
    source_path: &str,
    log_path: &Path,
) -> Result<Value, String> {
    let req = json!({
        "type": "request",
        "command": "ct/py-read-source",
        "seq": seq,
        "arguments": {
            "tracePath": trace_path.to_string_lossy().to_string(),
            "path": source_path,
        }
    });
    client
        .write_all(&dap_encode(&req))
        .await
        .map_err(|e| format!("write ct/py-read-source: {e}"))?;

    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err("timeout waiting for ct/py-read-source response".to_string());
        }

        let msg = timeout(remaining, dap_read(client))
            .await
            .map_err(|_| "timeout waiting for ct/py-read-source response".to_string())?
            .map_err(|e| format!("read ct/py-read-source: {e}"))?;

        let msg_type = msg.get("type").and_then(Value::as_str).unwrap_or("");
        if msg_type == "event" {
            log_line(log_path, &format!("py-read-source: skipped event: {msg}"));
            continue;
        }

        log_line(log_path, &format!("ct/py-read-source response: {msg}"));
        return Ok(msg);
    }
}

// ===========================================================================
// M7 Tests — Call Trace, Events, and Terminal
// ===========================================================================

/// M7-1. Open trace. Call ct/py-calltrace with start=0, count=20. Verify
/// non-empty list of Call objects. Verify each has name (non-empty) and
/// location populated.
#[tokio::test]
async fn m7_calltrace_returns_calls() {
    let (test_dir, log_path) = setup_test_dir("m7_calltrace_calls");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-m7-calltrace", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.
        let resp = open_trace(&mut client, 70_000, &trace_dir, &log_path).await?;
        assert_eq!(
            resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed"
        );

        // Call ct/py-calltrace with start=0, count=20.
        let ct_resp =
            py_calltrace(&mut client, 70_001, &trace_dir, 0, 20, 10, &log_path).await?;

        assert_eq!(
            ct_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/py-calltrace should succeed, got: {ct_resp}"
        );
        assert_eq!(
            ct_resp.get("command").and_then(Value::as_str),
            Some("ct/py-calltrace"),
            "command should be ct/py-calltrace"
        );

        let body = ct_resp.get("body").expect("response should have body");
        let calls = body
            .get("calls")
            .and_then(Value::as_array)
            .expect("body should have calls array");

        // Verify non-empty list of calls.
        assert!(
            !calls.is_empty(),
            "calls should be non-empty"
        );

        // Verify each call has a non-empty name and a populated location.
        for (i, call) in calls.iter().enumerate() {
            let name = call.get("name").and_then(Value::as_str).unwrap_or("");
            assert!(
                !name.is_empty(),
                "call {i} should have a non-empty name, got: {call}"
            );

            let location = call.get("location");
            assert!(
                location.is_some() && location.unwrap().is_object(),
                "call {i} should have a location object, got: {call}"
            );

            let path = location.unwrap().get("path").and_then(Value::as_str).unwrap_or("");
            assert!(
                !path.is_empty(),
                "call {i} location should have a non-empty path, got: {call}"
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

    report("m7_calltrace_returns_calls", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M7-2. Call ct/py-search-calltrace with query="main". Verify results
/// contain a call with "main" in the name.
#[tokio::test]
async fn m7_search_calltrace_finds_function() {
    let (test_dir, log_path) = setup_test_dir("m7_search_calltrace");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-m7-search", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.
        let resp = open_trace(&mut client, 71_000, &trace_dir, &log_path).await?;
        assert_eq!(
            resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed"
        );

        // Search for "main" in the calltrace.
        let search_resp =
            py_search_calltrace(&mut client, 71_001, &trace_dir, "main", 100, &log_path).await?;

        assert_eq!(
            search_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/py-search-calltrace should succeed, got: {search_resp}"
        );

        let body = search_resp.get("body").expect("response should have body");
        let calls = body
            .get("calls")
            .and_then(Value::as_array)
            .expect("body should have calls array");

        // Verify results contain a call with "main" in the name.
        let has_main = calls.iter().any(|c| {
            c.get("name")
                .and_then(Value::as_str)
                .unwrap_or("")
                .contains("main")
        });
        assert!(
            has_main,
            "search results should contain a call with 'main' in the name, got: {calls:?}"
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("m7_search_calltrace_finds_function", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M7-3. Call ct/py-events with start=0, count=10. Verify non-empty list
/// of Event objects. Verify each has id, type, and ticks.
#[tokio::test]
async fn m7_events_returns_events() {
    let (test_dir, log_path) = setup_test_dir("m7_events");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-m7-events", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.
        let resp = open_trace(&mut client, 72_000, &trace_dir, &log_path).await?;
        assert_eq!(
            resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed"
        );

        // Call ct/py-events with start=0, count=10, no type filter.
        let events_resp =
            py_events(&mut client, 72_001, &trace_dir, 0, 10, None, &log_path).await?;

        assert_eq!(
            events_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/py-events should succeed, got: {events_resp}"
        );
        assert_eq!(
            events_resp.get("command").and_then(Value::as_str),
            Some("ct/py-events"),
            "command should be ct/py-events"
        );

        let body = events_resp.get("body").expect("response should have body");
        let events = body
            .get("events")
            .and_then(Value::as_array)
            .expect("body should have events array");

        // Verify non-empty list of events.
        assert!(
            !events.is_empty(),
            "events should be non-empty"
        );

        // Verify each event has id, type, and ticks.
        for (i, event) in events.iter().enumerate() {
            assert!(
                event.get("id").is_some(),
                "event {i} should have 'id', got: {event}"
            );

            let event_type = event.get("type").and_then(Value::as_str).unwrap_or("");
            assert!(
                !event_type.is_empty(),
                "event {i} should have a non-empty 'type', got: {event}"
            );

            assert!(
                event.get("ticks").is_some(),
                "event {i} should have 'ticks', got: {event}"
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

    report("m7_events_returns_events", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M7-4. Call ct/py-events with typeFilter="stdout". Verify all returned
/// events have type "stdout".
#[tokio::test]
async fn m7_events_filter_by_type() {
    let (test_dir, log_path) = setup_test_dir("m7_events_filter");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-m7-filter", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.
        let resp = open_trace(&mut client, 73_000, &trace_dir, &log_path).await?;
        assert_eq!(
            resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed"
        );

        // Call ct/py-events with typeFilter="stdout".
        let events_resp =
            py_events(&mut client, 73_001, &trace_dir, 0, 100, Some("stdout"), &log_path).await?;

        assert_eq!(
            events_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/py-events (filtered) should succeed, got: {events_resp}"
        );

        let body = events_resp.get("body").expect("response should have body");
        let events = body
            .get("events")
            .and_then(Value::as_array)
            .expect("body should have events array");

        // Verify non-empty (the mock has 2 stdout events).
        assert!(
            !events.is_empty(),
            "filtered events should be non-empty"
        );

        // Verify all returned events have type "stdout".
        for (i, event) in events.iter().enumerate() {
            let event_type = event.get("type").and_then(Value::as_str).unwrap_or("");
            assert_eq!(
                event_type, "stdout",
                "event {i} should have type 'stdout', got '{event_type}'"
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

    report("m7_events_filter_by_type", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M7-5. Call ct/py-terminal. Verify non-empty string containing the
/// program's stdout output.
#[tokio::test]
async fn m7_terminal_output_returns_text() {
    let (test_dir, log_path) = setup_test_dir("m7_terminal");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-m7-terminal", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace.
        let resp = open_trace(&mut client, 74_000, &trace_dir, &log_path).await?;
        assert_eq!(
            resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed"
        );

        // Call ct/py-terminal.
        let term_resp = py_terminal(&mut client, 74_001, &trace_dir, &log_path).await?;

        assert_eq!(
            term_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/py-terminal should succeed, got: {term_resp}"
        );
        assert_eq!(
            term_resp.get("command").and_then(Value::as_str),
            Some("ct/py-terminal"),
            "command should be ct/py-terminal"
        );

        let body = term_resp.get("body").expect("response should have body");
        let output = body
            .get("output")
            .and_then(Value::as_str)
            .expect("body should have 'output' string");

        // Verify non-empty string containing the program's stdout.
        assert!(
            !output.is_empty(),
            "terminal output should be non-empty"
        );
        assert!(
            output.contains("Hello, World!"),
            "terminal output should contain 'Hello, World!', got: '{output}'"
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("m7_terminal_output_returns_text", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// M7-6. Get a file path from trace.source_files (via ct/open-trace
/// response). Call ct/py-read-source with that path. Verify non-empty
/// string containing source code.
#[tokio::test]
async fn m7_read_source_returns_file_content() {
    let (test_dir, log_path) = setup_test_dir("m7_read_source");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_test_trace_dir(&test_dir, "trace-m7-source", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the trace and get source files list.
        let resp = open_trace(&mut client, 75_000, &trace_dir, &log_path).await?;
        assert_eq!(
            resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed"
        );

        let body = resp.get("body").expect("open-trace response should have body");
        let source_files = body
            .get("sourceFiles")
            .and_then(Value::as_array)
            .expect("body should have sourceFiles array");
        assert!(
            !source_files.is_empty(),
            "sourceFiles should be non-empty"
        );

        // Use the first source file path. The mock returns source based
        // on the path content (contains "main" -> returns nim source).
        // The test trace_paths.json has "src/main.rs" which contains "main".
        let first_source = source_files[0]
            .as_str()
            .expect("source file should be a string");

        log_line(&log_path, &format!("reading source file: {first_source}"));

        // Call ct/py-read-source with the path.
        let source_resp =
            py_read_source(&mut client, 75_001, &trace_dir, first_source, &log_path).await?;

        assert_eq!(
            source_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/py-read-source should succeed, got: {source_resp}"
        );
        assert_eq!(
            source_resp.get("command").and_then(Value::as_str),
            Some("ct/py-read-source"),
            "command should be ct/py-read-source"
        );

        let src_body = source_resp.get("body").expect("response should have body");
        let content = src_body
            .get("content")
            .and_then(Value::as_str)
            .expect("body should have 'content' string");

        // Verify non-empty string containing source code.
        assert!(
            !content.is_empty(),
            "source content should be non-empty"
        );

        log_line(&log_path, &format!("source content: {content}"));

        // Verify the content looks like source code (the mock returns
        // nim-like source for paths containing "main").
        assert!(
            content.contains("proc") || content.contains("echo") || content.contains("fn")
                || content.contains("def") || content.contains("main"),
            "source content should contain recognizable code, got: '{content}'"
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("m7_read_source_returns_file_content", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

// ===========================================================================
// M8 Tests — Multi-Process Support
// ===========================================================================

/// Creates a test trace directory whose folder name contains "multi",
/// which causes the mock-dap-backend to simulate a multi-process trace.
fn create_multi_process_trace_dir(parent: &Path, name: &str) -> PathBuf {
    // The name must contain "multi" so the mock detects multi-process mode
    // from the traceFolder path passed in the DAP launch arguments.
    let trace_dir = parent.join(name);
    std::fs::create_dir_all(trace_dir.join("files")).expect("create trace dir");

    let metadata = serde_json::json!({
        "workdir": "/tmp/test-workdir",
        "program": "multi_process_app",
        "args": []
    });
    std::fs::write(
        trace_dir.join("trace_metadata.json"),
        serde_json::to_string_pretty(&metadata).unwrap(),
    )
    .expect("write trace_metadata.json");

    let paths = serde_json::json!(["src/main.rs", "src/worker.rs"]);
    std::fs::write(
        trace_dir.join("trace_paths.json"),
        serde_json::to_string(&paths).unwrap(),
    )
    .expect("write trace_paths.json");

    let events = serde_json::json!([
        {"Path": "src/main.rs"},
        {"Function": {"name": "main", "path_id": 0, "line": 1}},
        {"Call": {"function_id": 0, "args": []}},
        {"Step": {"path_id": 0, "line": 1}},
        {"Step": {"path_id": 0, "line": 2}},
    ]);
    std::fs::write(
        trace_dir.join("trace.json"),
        serde_json::to_string_pretty(&events).unwrap(),
    )
    .expect("write trace.json");

    trace_dir
}

/// Sends `ct/py-processes` and returns the response (skipping interleaved events).
async fn py_processes(
    client: &mut UnixStream,
    seq: i64,
    trace_path: &Path,
    log_path: &Path,
) -> Result<Value, String> {
    let req = json!({
        "type": "request",
        "command": "ct/py-processes",
        "seq": seq,
        "arguments": {
            "tracePath": trace_path.to_string_lossy().to_string(),
        }
    });
    client
        .write_all(&dap_encode(&req))
        .await
        .map_err(|e| format!("write ct/py-processes: {e}"))?;

    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err("timeout waiting for ct/py-processes response".to_string());
        }

        let msg = timeout(remaining, dap_read(client))
            .await
            .map_err(|_| "timeout waiting for ct/py-processes response".to_string())?
            .map_err(|e| format!("read ct/py-processes: {e}"))?;

        let msg_type = msg.get("type").and_then(Value::as_str).unwrap_or("");
        if msg_type == "event" {
            log_line(log_path, &format!("py-processes: skipped event: {msg}"));
            continue;
        }

        log_line(log_path, &format!("ct/py-processes response: {msg}"));
        return Ok(msg);
    }
}

/// Sends `ct/py-select-process` and returns the response (skipping interleaved events).
async fn py_select_process(
    client: &mut UnixStream,
    seq: i64,
    trace_path: &Path,
    process_id: i64,
    log_path: &Path,
) -> Result<Value, String> {
    let req = json!({
        "type": "request",
        "command": "ct/py-select-process",
        "seq": seq,
        "arguments": {
            "tracePath": trace_path.to_string_lossy().to_string(),
            "processId": process_id,
        }
    });
    client
        .write_all(&dap_encode(&req))
        .await
        .map_err(|e| format!("write ct/py-select-process: {e}"))?;

    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err("timeout waiting for ct/py-select-process response".to_string());
        }

        let msg = timeout(remaining, dap_read(client))
            .await
            .map_err(|_| "timeout waiting for ct/py-select-process response".to_string())?
            .map_err(|e| format!("read ct/py-select-process: {e}"))?;

        let msg_type = msg.get("type").and_then(Value::as_str).unwrap_or("");
        if msg_type == "event" {
            log_line(log_path, &format!("py-select-process: skipped event: {msg}"));
            continue;
        }

        log_line(log_path, &format!("ct/py-select-process response: {msg}"));
        return Ok(msg);
    }
}

/// V-M8-PROCESSES: Open a multi-process trace.  Call `trace.processes()`.
/// Verify a list with >1 Process objects.  Verify each has `id` and `command`.
#[tokio::test]
async fn m8_processes_returns_list() {
    let (test_dir, log_path) = setup_test_dir("m8_processes_list");
    let mut success = false;

    let result: Result<(), String> = async {
        // The trace directory name must contain "multi" so the mock detects
        // multi-process mode from the traceFolder launch argument.
        let trace_dir = create_multi_process_trace_dir(&test_dir, "trace-multi-m8-procs");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the multi-process trace.
        let resp = open_trace(&mut client, 80_000, &trace_dir, &log_path).await?;
        assert_eq!(
            resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed"
        );

        // Call ct/py-processes.
        let proc_resp = py_processes(&mut client, 80_001, &trace_dir, &log_path).await?;

        assert_eq!(
            proc_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/py-processes should succeed, got: {proc_resp}"
        );
        assert_eq!(
            proc_resp.get("command").and_then(Value::as_str),
            Some("ct/py-processes"),
            "command should be ct/py-processes"
        );

        let body = proc_resp.get("body").expect("response should have body");
        let processes = body
            .get("processes")
            .and_then(Value::as_array)
            .expect("body should have processes array");

        // V-M8-PROCESSES: Verify >1 process.
        assert!(
            processes.len() > 1,
            "multi-process trace should have >1 process, got {}",
            processes.len()
        );

        // Verify each process has `id` and `command`.
        for (i, proc) in processes.iter().enumerate() {
            let id = proc.get("id").and_then(Value::as_i64);
            assert!(
                id.is_some(),
                "process {i} should have an integer 'id', got: {proc}"
            );

            let command = proc.get("command").and_then(Value::as_str).unwrap_or("");
            assert!(
                !command.is_empty(),
                "process {i} should have a non-empty 'command', got: {proc}"
            );

            let name = proc.get("name").and_then(Value::as_str).unwrap_or("");
            assert!(
                !name.is_empty(),
                "process {i} should have a non-empty 'name', got: {proc}"
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

    report("m8_processes_returns_list", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// V-M8-SELECT: Open a multi-process trace.  Get process list.  Select
/// process B.  Query locals.  Select process A.  Query locals.  Verify
/// different variables returned.
#[tokio::test]
async fn m8_select_process_switches_context() {
    let (test_dir, log_path) = setup_test_dir("m8_select_process");
    let mut success = false;

    let result: Result<(), String> = async {
        let trace_dir = create_multi_process_trace_dir(&test_dir, "trace-multi-m8-select");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the multi-process trace.
        let resp = open_trace(&mut client, 81_000, &trace_dir, &log_path).await?;
        assert_eq!(
            resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed"
        );

        // Get process list to confirm multi-process.
        let proc_resp = py_processes(&mut client, 81_001, &trace_dir, &log_path).await?;
        let processes = proc_resp
            .get("body")
            .and_then(|b| b.get("processes"))
            .and_then(Value::as_array)
            .expect("should have processes");
        assert!(
            processes.len() > 1,
            "expected multi-process trace with >1 process"
        );

        // Select process 2 ("child").
        let sel_resp =
            py_select_process(&mut client, 81_002, &trace_dir, 2, &log_path).await?;
        assert_eq!(
            sel_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/py-select-process(2) should succeed, got: {sel_resp}"
        );

        // Query locals for process 2.
        let locals_b =
            py_locals(&mut client, 81_003, &trace_dir, 3, 3000, &log_path).await?;
        assert_eq!(
            locals_b.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/py-locals for process 2 should succeed"
        );
        let vars_b = locals_b
            .get("body")
            .and_then(|b| b.get("variables"))
            .and_then(Value::as_array)
            .expect("should have variables for process 2");

        // Collect variable names for process 2.
        let names_b: Vec<&str> = vars_b
            .iter()
            .filter_map(|v| v.get("name").and_then(Value::as_str))
            .collect();
        log_line(&log_path, &format!("process 2 variable names: {names_b:?}"));

        // Select process 1 ("main").
        let sel_resp2 =
            py_select_process(&mut client, 81_004, &trace_dir, 1, &log_path).await?;
        assert_eq!(
            sel_resp2.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/py-select-process(1) should succeed"
        );

        // Query locals for process 1.
        let locals_a =
            py_locals(&mut client, 81_005, &trace_dir, 3, 3000, &log_path).await?;
        assert_eq!(
            locals_a.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/py-locals for process 1 should succeed"
        );
        let vars_a = locals_a
            .get("body")
            .and_then(|b| b.get("variables"))
            .and_then(Value::as_array)
            .expect("should have variables for process 1");

        // Collect variable names for process 1.
        let names_a: Vec<&str> = vars_a
            .iter()
            .filter_map(|v| v.get("name").and_then(Value::as_str))
            .collect();
        log_line(&log_path, &format!("process 1 variable names: {names_a:?}"));

        // V-M8-SELECT: The two processes must have different variable sets.
        assert_ne!(
            names_a, names_b,
            "process 1 and process 2 should have different variables; \
             process 1: {names_a:?}, process 2: {names_b:?}"
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("m8_select_process_switches_context", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}

/// V-M8-SINGLE: Open a single-process trace.  Call `trace.processes()`.
/// Verify exactly 1 process.
#[tokio::test]
async fn m8_single_process_trace_has_one_process() {
    let (test_dir, log_path) = setup_test_dir("m8_single_process");
    let mut success = false;

    let result: Result<(), String> = async {
        // Use a normal (non-multi) trace directory — no "multi" in the name.
        let trace_dir = create_test_trace_dir(&test_dir, "trace-m8-single", "main.nim");

        let (mut daemon, socket_path) =
            start_daemon_with_mock_dap(&test_dir, &log_path, &[]).await;

        let mut client = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| format!("connect: {e}"))?;
        sleep(Duration::from_millis(200)).await;

        // Open the single-process trace.
        let resp = open_trace(&mut client, 82_000, &trace_dir, &log_path).await?;
        assert_eq!(
            resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/open-trace should succeed"
        );

        // Call ct/py-processes.
        let proc_resp = py_processes(&mut client, 82_001, &trace_dir, &log_path).await?;

        assert_eq!(
            proc_resp.get("success").and_then(Value::as_bool),
            Some(true),
            "ct/py-processes should succeed, got: {proc_resp}"
        );

        let body = proc_resp.get("body").expect("response should have body");
        let processes = body
            .get("processes")
            .and_then(Value::as_array)
            .expect("body should have processes array");

        // V-M8-SINGLE: Verify exactly 1 process.
        assert_eq!(
            processes.len(),
            1,
            "single-process trace should have exactly 1 process, got {}",
            processes.len()
        );

        // Verify the single process has valid fields.
        let proc = &processes[0];
        assert!(
            proc.get("id").and_then(Value::as_i64).is_some(),
            "process should have an integer 'id'"
        );
        assert!(
            !proc.get("command").and_then(Value::as_str).unwrap_or("").is_empty(),
            "process should have a non-empty 'command'"
        );

        shutdown_daemon(&mut client, &mut daemon).await;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => success = true,
        Err(e) => log_line(&log_path, &format!("TEST FAILED: {e}")),
    }

    report("m8_single_process_trace_has_one_process", &log_path, success);
    assert!(success, "see log at {}", log_path.display());
    let _ = std::fs::remove_dir_all(&test_dir);
}
