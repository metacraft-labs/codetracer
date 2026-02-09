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

    let resp = timeout(Duration::from_secs(5), dap_read(client))
        .await
        .map_err(|_| "timeout waiting for daemon-status response".to_string())?
        .map_err(|e| format!("read daemon-status response: {e}"))?;

    log_line(log_path, &format!("daemon-status response: {resp}"));

    if resp.get("success").and_then(Value::as_bool) != Some(true) {
        return Err(format!("daemon-status not successful: {resp}"));
    }

    resp.get("body")
        .cloned()
        .ok_or_else(|| format!("missing body in daemon-status response: {resp}"))
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
