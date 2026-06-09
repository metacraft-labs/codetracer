//! Headless DAP driver used by the P4 GUI-ops latency bench.
//!
//! The driver spawns `replay-server dap-server --stdio` as a subprocess,
//! performs the standard DAP initialise → launch → configurationDone
//! handshake against a pre-recorded trace, and then issues one DAP
//! request per measured operation, timing the round-trip wall-clock per
//! iteration to compute p50 / p95.
//!
//! ## Wire format
//!
//! DAP messages are sent over stdio as
//! `Content-Length: N\r\n\r\n<json>` blocks (see
//! [the DAP spec](https://microsoft.github.io/debug-adapter-protocol/specification)).
//! We carry a small ring-buffer of bytes we've read but not yet
//! consumed; each call to [`DapSession::send_and_wait`] writes one
//! request and drains messages until the matching response shows up.
//!
//! ## Field naming
//!
//! The Rust-side `LaunchRequestArguments` mixes camelCase
//! (`traceFolder`) and snake_case (`trace_file`) field names because
//! the codetracer launch surface evolved alongside DAP's
//! VSCode-derived conventions. We mirror the on-the-wire names exactly
//! here.

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

/// Result of a per-operation bench.  Carries the latency percentiles
/// plus a sample of the dap-server response so the matrix-builder can
/// run correctness assertions against the actual operation output.
///
/// `success_count` lets the bench distinguish a fast wire-loop
/// round-trip from a real successful operation: a zero
/// `success_count` with a non-empty `failure_message` is the
/// dap-server rejecting every iteration with "missing field X"
/// or similar — that's a bench design bug (or a recorder
/// regression), not a measurement.
#[derive(Debug, Clone)]
pub struct BenchOutcome {
    pub p50_ms: f64,
    pub p95_ms: f64,
    pub iterations: usize,
    pub success_count: usize,
    pub first_response_body: Option<Value>,
    pub failure_message: Option<String>,
}

/// Owns the spawned dap-server subprocess plus the read buffer used to
/// peel out one DAP message at a time.
pub struct DapSession {
    child: Child,
    stdin: std::process::ChildStdin,
    stdout: BufReader<std::process::ChildStdout>,
    seq: i64,
    /// Pending response bytes that have been read from stdout but not
    /// yet consumed by a caller.  We stash unrelated events here when
    /// `send_and_wait` is filtering for a specific `request_seq`.
    buffered_messages: Vec<Value>,
}

/// Errors the driver surfaces.  Maintains the campaign's discipline of
/// keeping the SKIP sentinel string narrow.
#[derive(Debug)]
pub enum DapError {
    /// Failed to spawn the subprocess (binary missing, permission
    /// denied, …).
    Spawn(String),
    /// Sub-process exited unexpectedly before the response arrived.
    SubprocessExited,
    /// Hit the wall-clock timeout waiting for a response.
    Timeout(String),
    /// Wire-format error (bad header, malformed JSON, …).
    Wire(String),
    /// The remote side returned `success: false` for a request.
    RequestFailed { command: String, message: String },
    /// I/O error reading/writing stdio.
    Io(String),
}

impl std::fmt::Display for DapError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DapError::Spawn(s) => write!(f, "dap-server spawn failed: {s}"),
            DapError::SubprocessExited => write!(f, "dap-server exited unexpectedly"),
            DapError::Timeout(s) => write!(f, "dap-server timeout: {s}"),
            DapError::Wire(s) => write!(f, "dap-server wire error: {s}"),
            DapError::RequestFailed { command, message } => {
                write!(f, "dap-server request {command} failed: {message}")
            }
            DapError::Io(s) => write!(f, "dap-server io error: {s}"),
        }
    }
}

impl std::error::Error for DapError {}

impl DapSession {
    /// Spawn the dap-server subprocess and run the initialise → launch
    /// → configurationDone handshake.  Waits for the `stopped` event
    /// before returning so callers can immediately issue
    /// `ct/load-locals` etc. against a stable frame.
    ///
    /// `dap_binary` is typically the path returned by
    /// [`crate::ct_binary`]; `trace_folder` is the directory the
    /// recorder wrote into; `trace_file` is the relative path of the
    /// `.ct` artefact inside the folder.
    ///
    /// Launch a DAP session through the user-facing `ct start_backend`
    /// CLI surface (preferred) or fall back to `replay-server
    /// dap-server` / `ct-rr-support` directly.  `backend_kind` is the
    /// argument `ct start_backend` accepts: `"db"` for materialized +
    /// MCR-via-replay-worker traces; `"rr"` for RR traces.
    ///
    /// The replay-worker (`ct-native-replay` / `ct-rr-support`) is
    /// resolved by the dap-server itself: it looks at the DAP launch
    /// `ctRRWorkerExe` field, then `CODETRACER_*_EXE` environment
    /// variables, then searches PATH.  The bench's
    /// `detect-siblings.sh` exposes `ct-native-replay` on PATH, so no
    /// per-cell `ctRRWorkerExe` plumbing is needed.
    pub fn launch(
        dap_binary: &Path,
        backend_kind: &str,
        trace_folder: &Path,
        trace_file: &str,
    ) -> Result<Self, DapError> {
        // Capture dap-server stderr so launch failures surface
        // visibly instead of being swallowed silently — the replay
        // worker spawn under MCR traces emits diagnostic lines that
        // are the only signal when a stopped event doesn't arrive.
        let stderr_target = if std::env::var_os("CT_BENCH_DEBUG_PENDING").is_some() {
            Stdio::inherit()
        } else {
            Stdio::null()
        };
        // Pick the right argv shape based on the binary name.  The
        // user-facing `ct` invokes `ct start_backend <kind> --stdio`;
        // the `replay-server` direct path uses `dap-server --stdio`;
        // `ct-rr-support` uses just `--stdio`.  We sniff the binary
        // name rather than threading another flag through callers.
        let exe_name = dap_binary
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("");
        let mut command = Command::new(dap_binary);
        match exe_name {
            "ct" => {
                command.arg("start_backend").arg(backend_kind).arg("--stdio");
            }
            "replay-server" => {
                command.arg("dap-server").arg("--stdio");
            }
            _ => {
                // Fall back to single-arg `--stdio` (matches the
                // `ct-rr-support` / older direct invocation).
                command.arg("--stdio");
            }
        }
        let mut child = command
            // CODETRACER_IN_UI_TEST=1 bypasses the free-tier daily
            // replay-quota gate the replay-worker enforces.  Matches
            // `ensure_replay_license_bypass()` in
            // codetracer/src/db-backend/tests/test_harness/mod.rs —
            // without it the worker exits with
            // `daily_replay_limit_reached` after a handful of
            // recordings and the dap-server never emits `stopped`.
            .env("CODETRACER_IN_UI_TEST", "1")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(stderr_target)
            .spawn()
            .map_err(|e| DapError::Spawn(e.to_string()))?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| DapError::Spawn("stdin pipe missing".to_string()))?;
        let stdout = BufReader::new(
            child
                .stdout
                .take()
                .ok_or_else(|| DapError::Spawn("stdout pipe missing".to_string()))?,
        );

        let mut session = Self {
            child,
            stdin,
            stdout,
            seq: 1,
            buffered_messages: Vec::new(),
        };

        // 1. initialize — server responds + emits `initialized` event.
        session.send_and_wait(
            "initialize",
            json!({ "clientID": "ct-bench" }),
            Duration::from_secs(5),
        )?;

        // 2. launch — store the trace metadata; the server does NOT
        //    forward the launch into the task thread until
        //    configurationDone has arrived.  Both responses come back
        //    immediately so we don't need to await them serially.
        //
        //    NOTE: the on-the-wire field is `trace_file` (snake_case)
        //    not `traceFile` — that's the codetracer convention.
        let trace_folder_str = trace_folder.to_string_lossy().to_string();
        let launch_args = json!({
            "traceFolder": trace_folder_str,
            "trace_file": trace_file,
        });
        // The replay-worker binary (`ct-native-replay` for MCR,
        // `ct-rr-support` for RR) is resolved by the dap-server's own
        // 3-tier discovery: DAP launch `ctRRWorkerExe` arg → env vars
        // (`CODETRACER_*_EXE`) → PATH search (see
        // db-backend/src/dap_server.rs::resolve_recreator_exe).  The
        // bench's `detect-siblings.sh` puts `ct-native-replay` on
        // PATH so launch args don't need to carry it.
        session.send_and_wait("launch", launch_args, Duration::from_secs(10))?;

        // 3. configurationDone — server forwards the cached launch
        //    request into the task thread which then runs the trace
        //    to entry + emits `stopped`.
        session.send_and_wait("configurationDone", json!({}), Duration::from_secs(30))?;

        // 4. Wait for the `stopped` event before returning so callers
        //    have a stable frame to query.
        //
        // Timeout budget matches `*_mcr_streaming_flow_test.rs` in
        // codetracer/src/db-backend/tests/ — 60s covers the
        // `ct-native-replay` worker-spawn time for MCR traces (which
        // is slower than the in-process Materialized path) plus the
        // M-RLP layout-snapshot decode that runs on first stop.
        let stopped_timeout = Duration::from_secs(60);
        let started = Instant::now();
        while started.elapsed() < stopped_timeout {
            match session.read_one_message(Duration::from_millis(500)) {
                Ok(Some(msg)) => {
                    if msg.get("type").and_then(Value::as_str) == Some("event")
                        && msg.get("event").and_then(Value::as_str) == Some("stopped")
                    {
                        // Got it — drain any trailing messages then
                        // return.
                        return Ok(session);
                    }
                    // Other events (e.g. `ct/complete-move`); stash and
                    // keep waiting.
                    session.buffered_messages.push(msg);
                }
                Ok(None) => continue,
                Err(DapError::Timeout(_)) => continue,
                Err(e) => return Err(e),
            }
        }
        Err(DapError::Timeout(format!(
            "stopped event not seen within {}s of configurationDone",
            stopped_timeout.as_secs()
        )))
    }

    /// Send a request and block until the response with the matching
    /// `request_seq` arrives.  Events and unrelated responses are
    /// stashed in [`DapSession::buffered_messages`] for later.
    ///
    /// Returns the response's `body` field (or `Value::Null` when
    /// absent).
    pub fn send_and_wait(
        &mut self,
        command: &str,
        arguments: Value,
        timeout: Duration,
    ) -> Result<Value, DapError> {
        let seq = self.seq;
        self.seq += 1;
        let req = json!({
            "seq": seq,
            "type": "request",
            "command": command,
            "arguments": arguments,
        });
        self.write_message(&req)?;

        // First drain any already-buffered matching response.
        if let Some(idx) = self.buffered_messages.iter().position(|m| {
            m.get("type").and_then(Value::as_str) == Some("response")
                && m.get("request_seq").and_then(Value::as_i64) == Some(seq)
        }) {
            let m = self.buffered_messages.remove(idx);
            return Self::extract_body(command, m);
        }

        let started = Instant::now();
        while started.elapsed() < timeout {
            // `timeout - started.elapsed()` overflows when the loop
            // condition was barely true and another thread preempted
            // before the subtraction — saturate at zero instead.
            let remaining = timeout.saturating_sub(started.elapsed());
            match self.read_one_message(remaining) {
                Ok(Some(msg)) => {
                    if msg.get("type").and_then(Value::as_str) == Some("response")
                        && msg.get("request_seq").and_then(Value::as_i64) == Some(seq)
                    {
                        return Self::extract_body(command, msg);
                    }
                    self.buffered_messages.push(msg);
                }
                Ok(None) => continue,
                Err(DapError::Timeout(_)) => continue,
                Err(e) => return Err(e),
            }
        }
        Err(DapError::Timeout(format!(
            "no response to {command}(seq={seq}) within {}ms",
            timeout.as_millis()
        )))
    }

    /// Block until an event with the given name arrives.  Buffered
    /// events are drained first, then we read off the stream until the
    /// match arrives or `timeout` elapses.  Non-matching messages stay
    /// buffered for later `send_and_wait` / `wait_for_event` calls.
    ///
    /// Used by the gui-ops bench's setup phase to wait for the
    /// `stopped` event that follows a `continue` / `stepIn` request —
    /// the dap-server only emits this when the step completes, so the
    /// caller cannot assume the trace cursor advanced just because the
    /// request response arrived.
    pub fn wait_for_event(
        &mut self,
        event_name: &str,
        timeout: Duration,
    ) -> Result<Value, DapError> {
        if let Some(idx) = self.buffered_messages.iter().position(|m| {
            m.get("type").and_then(Value::as_str) == Some("event")
                && m.get("event").and_then(Value::as_str) == Some(event_name)
        }) {
            return Ok(self.buffered_messages.remove(idx));
        }
        let started = Instant::now();
        while started.elapsed() < timeout {
            let remaining = timeout.saturating_sub(started.elapsed());
            match self.read_one_message(remaining) {
                Ok(Some(msg)) => {
                    if msg.get("type").and_then(Value::as_str) == Some("event")
                        && msg.get("event").and_then(Value::as_str) == Some(event_name)
                    {
                        return Ok(msg);
                    }
                    self.buffered_messages.push(msg);
                }
                Ok(None) => continue,
                Err(DapError::Timeout(_)) => continue,
                Err(e) => return Err(e),
            }
        }
        Err(DapError::Timeout(format!(
            "{event_name} event not seen within {}ms",
            timeout.as_millis()
        )))
    }

    fn extract_body(command: &str, msg: Value) -> Result<Value, DapError> {
        let success = msg.get("success").and_then(Value::as_bool).unwrap_or(false);
        if !success {
            let message = msg
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("(no message)")
                .to_string();
            return Err(DapError::RequestFailed {
                command: command.to_string(),
                message,
            });
        }
        Ok(msg.get("body").cloned().unwrap_or(Value::Null))
    }

    fn write_message(&mut self, value: &Value) -> Result<(), DapError> {
        let body =
            serde_json::to_vec(value).map_err(|e| DapError::Wire(format!("serialise: {e}")))?;
        let header = format!("Content-Length: {}\r\n\r\n", body.len());
        self.stdin
            .write_all(header.as_bytes())
            .map_err(|e| DapError::Io(e.to_string()))?;
        self.stdin
            .write_all(&body)
            .map_err(|e| DapError::Io(e.to_string()))?;
        self.stdin
            .flush()
            .map_err(|e| DapError::Io(e.to_string()))?;
        Ok(())
    }

    /// Read one DAP message off the stream.  Returns `Ok(None)` when
    /// the stream closed cleanly mid-read (the caller decides whether
    /// that's an error).
    ///
    /// The implementation uses raw `poll(2)` on the underlying file
    /// descriptor so the wall-clock timeout actually fires regardless
    /// of what state the dap-server's stdout is in.
    /// `BufReader::read_line` alone would block indefinitely on a pipe
    /// with no data — the polling loop interleaves bounded blocking
    /// reads with `poll(2)` checks so a stalled server surfaces as a
    /// [`DapError::Timeout`] rather than freezing the bench driver.
    fn read_one_message(&mut self, timeout: Duration) -> Result<Option<Value>, DapError> {
        #[cfg(unix)]
        fn poll_readable(fd: i32, slice: Duration) -> bool {
            #[repr(C)]
            struct PollFd {
                fd: i32,
                events: i16,
                revents: i16,
            }
            unsafe extern "C" {
                fn poll(fds: *mut PollFd, nfds: u64, timeout_ms: i32) -> i32;
            }
            const POLLIN: i16 = 0x001;
            let mut pfd = PollFd {
                fd,
                events: POLLIN,
                revents: 0,
            };
            let ms = slice.as_millis().min(i32::MAX as u128) as i32;
            // SAFETY: pfd is correctly initialised; nfds=1 matches the
            // single-element buffer we pass.
            let rc = unsafe { poll(&mut pfd as *mut PollFd, 1, ms) };
            rc > 0
        }
        #[cfg(not(unix))]
        fn poll_readable(_fd: i32, slice: Duration) -> bool {
            std::thread::sleep(slice);
            true
        }

        let fd: i32 = {
            use std::os::unix::io::AsRawFd;
            self.stdout.get_ref().as_raw_fd()
        };

        let started = Instant::now();
        let mut header = Vec::<u8>::new();
        loop {
            if started.elapsed() >= timeout {
                return Err(DapError::Timeout(format!(
                    "header read timeout after {}ms",
                    timeout.as_millis()
                )));
            }
            // Only block on the descriptor when the BufReader has
            // nothing buffered — the previous body's `read_exact` may
            // have left the next header bytes already buffered, in
            // which case we want to skip the poll and consume them
            // immediately.
            if self.stdout.buffer().is_empty() {
                let remaining = timeout.saturating_sub(started.elapsed());
                let slice = remaining.min(Duration::from_millis(200));
                if !poll_readable(fd, slice) {
                    if let Ok(Some(_)) = self.child.try_wait() {
                        return Err(DapError::SubprocessExited);
                    }
                    continue;
                }
            }
            let mut line = String::new();
            match self.stdout.read_line(&mut line) {
                Ok(0) => match self.child.try_wait() {
                    Ok(Some(_)) => return Err(DapError::SubprocessExited),
                    _ => return Ok(None),
                },
                Ok(_) => {
                    header.extend_from_slice(line.as_bytes());
                    if line == "\r\n" {
                        break;
                    }
                }
                Err(e) => return Err(DapError::Io(e.to_string())),
            }
        }

        // Parse Content-Length from header.
        let header_str = std::str::from_utf8(&header)
            .map_err(|e| DapError::Wire(format!("header utf8: {e}")))?;
        let mut content_length: Option<usize> = None;
        for h in header_str.split("\r\n") {
            let h_lower = h.to_ascii_lowercase();
            if let Some(rest) = h_lower.strip_prefix("content-length:") {
                content_length = rest.trim().parse().ok();
            }
        }
        let cl =
            content_length.ok_or_else(|| DapError::Wire("missing Content-Length".to_string()))?;
        let mut body = vec![0u8; cl];
        self.stdout
            .read_exact(&mut body)
            .map_err(|e| DapError::Io(e.to_string()))?;
        let value: Value =
            serde_json::from_slice(&body).map_err(|e| DapError::Wire(format!("json: {e}")))?;
        Ok(Some(value))
    }

    /// Result of [`DapSession::bench`].  Carries the latency
    /// percentiles plus a sample of the first response body so callers
    /// can run correctness assertions against the actual operation
    /// output (not just the round-trip time).
    ///
    /// `success_count` tracks how many of the `iterations` returned a
    /// `success: true` response.  A non-zero `failure_count` indicates
    /// the dap-server rejected the request — the bench surfaces this
    /// as a correctness failure rather than letting it silently
    /// degrade the latency-only column.
    pub fn bench(
        &mut self,
        command: &str,
        arguments: Value,
        iterations: usize,
    ) -> Result<BenchOutcome, DapError> {
        let mut samples = Vec::with_capacity(iterations);
        let mut success_count = 0usize;
        let mut failure_message: Option<String> = None;
        let mut first_body: Option<Value> = None;
        for _ in 0..iterations {
            let started = Instant::now();
            match self.send_and_wait(command, arguments.clone(), Duration::from_secs(15)) {
                Ok(body) => {
                    success_count += 1;
                    if first_body.is_none() {
                        first_body = Some(body);
                    }
                }
                Err(DapError::RequestFailed { message, .. }) => {
                    if failure_message.is_none() {
                        failure_message = Some(message);
                    }
                }
                Err(e) => return Err(e),
            }
            samples.push(started.elapsed().as_secs_f64() * 1000.0);
        }
        samples.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        let p50 = samples[samples.len() / 2];
        let p95_idx = ((samples.len() as f64) * 0.95) as usize;
        let p95 = samples[p95_idx.min(samples.len() - 1)];
        Ok(BenchOutcome {
            p50_ms: p50,
            p95_ms: p95,
            iterations,
            success_count,
            first_response_body: first_body,
            failure_message,
        })
    }
}

impl Drop for DapSession {
    fn drop(&mut self) {
        // Best-effort: try a clean disconnect, then kill.
        let _ = self.write_message(&json!({
            "seq": self.seq,
            "type": "request",
            "command": "disconnect",
            "arguments": {},
        }));
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
