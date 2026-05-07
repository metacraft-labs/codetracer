//! Shared test harness for DAP-based integration tests
//!
//! This module provides abstractions for:
//! - Building and recording test programs
//! - Managing DAP client connections
//! - Running flow tests across different language versions
//!
//! # Design
//!
//! The harness separates concerns into:
//! - `TestRecording`: A compiled and recorded trace that can be reused across tests
//! - `DapTestClient`: A wrapper around the DAP client with test-friendly helpers
//! - `FlowTestCase`: Configuration for running flow-based tests

#![allow(dead_code)]
#![allow(unused_variables)]

use db_backend::dap::{self, DapClient, DapMessage, LaunchRequestArguments};
use db_backend::task::{CtLoadFlowArguments, FlowMode, Location};
use db_backend::transport::DapTransport;
use serde_json::json;
use std::collections::HashMap;
use std::env;
use std::fs;
use std::io::BufReader;
#[cfg(unix)]
use std::io::{self, ErrorKind};
#[cfg(unix)]
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::thread;
use std::time::{Duration, Instant};

/// Canonicalize a path, stripping the Windows `\\?\` UNC prefix if present.
///
/// Rust's `std::fs::canonicalize` on Windows returns extended-length paths
/// prefixed with `\\?\` (e.g. `\\?\D:\foo\bar`). Many tools (Node.js, Ruby)
/// cannot handle this prefix and fail with confusing errors like
/// `EISDIR: illegal operation on a directory, lstat 'D:'`.
///
/// This helper strips the prefix so callers get a normal absolute path.
fn safe_canonicalize(path: &Path) -> PathBuf {
    match path.canonicalize() {
        Ok(p) => {
            #[cfg(windows)]
            {
                let s = p.to_string_lossy();
                if let Some(stripped) = s.strip_prefix(r"\\?\") {
                    return PathBuf::from(stripped);
                }
            }
            p
        }
        Err(_) => path.to_path_buf(),
    }
}

/// Derive the repo root directory from a recorder binary path.
///
/// Given a path like `.../codetracer-circom-recorder/target/release/codetracer-circom-recorder`,
/// walks up to find the repo root (the directory containing `.envrc`).
/// Returns `None` if no `.envrc` is found in any ancestor.
fn find_recorder_repo_dir(recorder_binary: &Path) -> Option<PathBuf> {
    let mut dir = recorder_binary.parent();
    while let Some(d) = dir {
        if d.join(".envrc").exists() {
            return Some(d.to_path_buf());
        }
        dir = d.parent();
    }
    None
}

/// Run a recorder command, wrapping it with `direnv exec <repo_dir>` when the
/// recorder lives in a sibling repo that has its own nix dev shell (`.envrc`).
///
/// This ensures that language-specific toolchains (e.g. `circom`, `leo`) are on
/// PATH even when the test is executed from a different repo's dev shell.
///
/// If the recorder binary does not live inside a repo with `.envrc`, the command
/// is executed directly without `direnv exec`.
fn run_recorder_command(recorder: &Path, args: &[&str]) -> Result<std::process::Output, String> {
    let repo_dir = find_recorder_repo_dir(recorder);

    let output = if let Some(ref repo_dir) = repo_dir {
        // Build the full command: direnv exec <repo_dir> <recorder> <args...>
        let mut cmd = Command::new("direnv");
        cmd.arg("exec").arg(repo_dir).arg(recorder).args(args);
        eprintln!(
            "Running recorder via direnv exec {} {} {}",
            repo_dir.display(),
            recorder.display(),
            args.join(" ")
        );
        cmd.output()
            .map_err(|e| format!("failed to run recorder via direnv: {}", e))?
    } else {
        Command::new(recorder)
            .args(args)
            .output()
            .map_err(|e| format!("failed to run recorder: {}", e))?
    };

    Ok(output)
}

/// Supported languages for test programs
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Language {
    Nim,
    Rust,
    C,
    Cpp,
    Go,
    Lean,
    Python,
    Ruby,
    Noir,
    RustWasm,
    JavaScript,
    Bash,
    Zsh,
    Stylus,
    /// EVM/Solidity: recorded by the codetracer-evm-recorder binary.
    /// Traces are DB-based (trace.json + trace_metadata.json).
    Solidity,
    /// Miden MASM: recorded by codetracer-miden-recorder
    Masm,
    /// Sway/FuelVM: recorded by codetracer-fuel-recorder
    Sway,
    /// Move/Sui: recorded by codetracer-move-recorder
    Move,
    /// Solana/SBF: recorded by codetracer-solana-recorder
    Solana,
    /// PolkaVM: recorded by codetracer-polkavm-recorder
    PolkaVM,
    /// Cairo: recorded by codetracer-cairo-recorder
    Cairo,
    /// Circom: recorded by codetracer-circom-recorder
    Circom,
    /// Leo: recorded by codetracer-leo-recorder
    Leo,
    /// Tolk: recorded by codetracer-ton-recorder
    Tolk,
    /// Aiken: recorded by codetracer-cardano-recorder
    Aiken,
    /// Cadence: recorded by codetracer-flow-recorder
    Cadence,
    /// Elixir/BEAM: recorded by codetracer-beam-recorder
    Elixir,
    /// Erlang/BEAM: recorded by codetracer-beam-recorder
    Erlang,
}

impl Language {
    pub fn extension(&self) -> &'static str {
        match self {
            Language::Nim => "nim",
            Language::Rust => "rs",
            Language::C => "c",
            Language::Cpp => "cpp",
            Language::Go => "go",
            Language::Lean => "lean",
            Language::Python => "py",
            Language::Ruby => "rb",
            Language::Noir => "nr",
            Language::RustWasm => "wasm",
            Language::JavaScript => "js",
            Language::Bash => "sh",
            Language::Zsh => "zsh",
            Language::Stylus => "stylus",
            Language::Solidity => "sol",
            Language::Masm => "masm",
            Language::Sway => "sw",
            Language::Move => "move",
            Language::Solana => "rs",
            Language::PolkaVM => "polkavm",
            Language::Cairo => "cairo",
            Language::Circom => "circom",
            Language::Leo => "leo",
            Language::Tolk => "tolk",
            Language::Aiken => "ak",
            Language::Cadence => "cdc",
            Language::Elixir => "ex",
            Language::Erlang => "erl",
        }
    }

    /// Returns true for DB-based trace languages (Python, Ruby, Noir, RustWasm) that don't use rr.
    pub fn is_db_trace(&self) -> bool {
        matches!(
            self,
            Language::Python
                | Language::Ruby
                | Language::Noir
                | Language::RustWasm
                | Language::JavaScript
                | Language::Bash
                | Language::Zsh
                | Language::Stylus
                | Language::Solidity
                | Language::Masm
                | Language::Sway
                | Language::Move
                | Language::Solana
                | Language::PolkaVM
                | Language::Cairo
                | Language::Circom
                | Language::Leo
                | Language::Tolk
                | Language::Aiken
                | Language::Cadence
                | Language::Elixir
                | Language::Erlang
        )
    }
}

/// A recorded trace that can be reused across multiple tests
pub struct TestRecording {
    pub trace_dir: PathBuf,
    pub source_path: PathBuf,
    pub binary_path: PathBuf,
    pub temp_dir: PathBuf,
    pub language: Language,
    pub version_label: String,
}

impl TestRecording {
    /// Create a new test recording by building and recording a program
    pub fn create(
        source_path: &Path,
        language: Language,
        version_label: &str,
        ct_rr_support: &Path,
    ) -> Result<Self, String> {
        let temp_dir = std::env::temp_dir().join(format!(
            "flow_test_{}_{}_{}",
            language.extension(),
            version_label.replace('.', "_"),
            std::process::id()
        ));

        // Clean up any existing temp directory. In sandboxed builds (nix),
        // remove_dir_all can fail with ENOTEMPTY if another test process
        // has handles open. Retry once after a short delay, then proceed.
        if temp_dir.exists() && fs::remove_dir_all(&temp_dir).is_err() {
            std::thread::sleep(std::time::Duration::from_millis(100));
            let _ = fs::remove_dir_all(&temp_dir);
        }
        fs::create_dir_all(&temp_dir).map_err(|e| format!("failed to create temp dir: {}", e))?;

        let trace_dir = temp_dir.join("trace");
        let binary_name = source_path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("test_program");
        let binary_path = temp_dir.join(format!("{}{}", binary_name, std::env::consts::EXE_SUFFIX));

        // Build the program
        let build_output = Command::new(ct_rr_support)
            .args(["build", source_path.to_str().unwrap(), binary_path.to_str().unwrap()])
            .output()
            .map_err(|e| format!("failed to run ct-native-replay build: {}", e))?;

        if !build_output.status.success() {
            return Err(format!(
                "Build failed:\nstdout: {}\nstderr: {}",
                String::from_utf8_lossy(&build_output.stdout),
                String::from_utf8_lossy(&build_output.stderr)
            ));
        }

        // Record the trace
        let record_output = Command::new(ct_rr_support)
            .args([
                "record",
                "-o",
                trace_dir.to_str().unwrap(),
                binary_path.to_str().unwrap(),
            ])
            .output()
            .map_err(|e| format!("failed to run ct-native-replay record: {}", e))?;

        if !record_output.status.success() {
            return Err(format!(
                "Record failed:\nstdout: {}\nstderr: {}",
                String::from_utf8_lossy(&record_output.stdout),
                String::from_utf8_lossy(&record_output.stderr)
            ));
        }

        Ok(TestRecording {
            trace_dir,
            source_path: source_path.to_path_buf(),
            binary_path,
            temp_dir,
            language,
            version_label: version_label.to_string(),
        })
    }

    /// Create a new test recording using the MCR backend.
    ///
    /// This builds the program with `ct-native-replay build` and then records
    /// it with `ct-native-replay record --backend mcr`, producing a `.ct` trace
    /// file instead of an rr trace directory.
    pub fn create_mcr(
        source_path: &Path,
        language: Language,
        version_label: &str,
        ct_rr_support: &Path,
    ) -> Result<Self, String> {
        let temp_dir = std::env::temp_dir().join(format!(
            "mcr_flow_test_{}_{}_{}",
            language.extension(),
            version_label.replace('.', "_"),
            std::process::id()
        ));

        if temp_dir.exists() && fs::remove_dir_all(&temp_dir).is_err() {
            std::thread::sleep(std::time::Duration::from_millis(100));
            let _ = fs::remove_dir_all(&temp_dir);
        }
        fs::create_dir_all(&temp_dir).map_err(|e| format!("failed to create temp dir: {}", e))?;

        let binary_name = source_path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("test_program");
        let binary_path = temp_dir.join(format!("{}{}", binary_name, std::env::consts::EXE_SUFFIX));

        // Build the program
        let build_output = Command::new(ct_rr_support)
            .args(["build", source_path.to_str().unwrap(), binary_path.to_str().unwrap()])
            .output()
            .map_err(|e| format!("failed to run ct-native-replay build: {}", e))?;

        if !build_output.status.success() {
            return Err(format!(
                "MCR build failed:\nstdout: {}\nstderr: {}",
                String::from_utf8_lossy(&build_output.stdout),
                String::from_utf8_lossy(&build_output.stderr)
            ));
        }

        // Record with MCR backend — produces a .ct file
        let trace_output = temp_dir.join("trace");
        let record_output = Command::new(ct_rr_support)
            .args([
                "record",
                "--backend",
                "mcr",
                "-o",
                trace_output.to_str().unwrap(),
                binary_path.to_str().unwrap(),
            ])
            .output()
            .map_err(|e| format!("failed to run ct-native-replay record --backend mcr: {}", e))?;

        if !record_output.status.success() {
            return Err(format!(
                "MCR record failed:\nstdout: {}\nstderr: {}",
                String::from_utf8_lossy(&record_output.stdout),
                String::from_utf8_lossy(&record_output.stderr)
            ));
        }

        // MCR produces a .ct file — find it in the temp directory
        let trace_ct = trace_output.with_extension("ct");
        let trace_dir = if trace_ct.exists() {
            trace_ct
        } else {
            // Fallback: look for any .ct file in the temp directory
            let mut found = None;
            if let Ok(entries) = fs::read_dir(&temp_dir) {
                for entry in entries.flatten() {
                    if entry.path().extension().and_then(|e| e.to_str()) == Some("ct") {
                        found = Some(entry.path());
                        break;
                    }
                }
            }
            found.ok_or_else(|| format!("MCR record did not produce a .ct trace file in {}", temp_dir.display()))?
        };

        Ok(TestRecording {
            trace_dir,
            source_path: source_path.to_path_buf(),
            binary_path,
            temp_dir,
            language,
            version_label: version_label.to_string(),
        })
    }
}

impl Drop for TestRecording {
    fn drop(&mut self) {
        // Clean up temp directory on drop
        fs::remove_dir_all(&self.temp_dir).ok();
    }
}

/// A DAP test client wrapper with helper methods
#[cfg(unix)]
pub struct DapTestClient {
    client: DapClient,
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    db_backend: Child,
    _listener: UnixListener,
}

#[cfg(unix)]
impl DapTestClient {
    /// Start a new DAP test client connected to db-backend
    pub fn start(temp_dir: &Path, ct_rr_support: &Path) -> Result<Self, String> {
        let db_backend_bin = env!("CARGO_BIN_EXE_replay-server");
        let socket_path = temp_dir.join("dap.sock");

        if socket_path.exists() {
            fs::remove_file(&socket_path).map_err(|e| format!("failed to remove socket: {}", e))?;
        }

        let listener = UnixListener::bind(&socket_path).map_err(|e| {
            if e.kind() == ErrorKind::PermissionDenied {
                "cannot bind to socket (permission denied)".to_string()
            } else {
                format!("failed to bind socket: {}", e)
            }
        })?;

        let db_backend = Command::new(db_backend_bin)
            .args(["dap-server", socket_path.to_str().unwrap()])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("failed to start db-backend: {}", e))?;

        let (stream, _) = accept_with_timeout(&listener, Duration::from_secs(10))
            .map_err(|e| format!("failed to accept connection: {}", e))?;

        // The listener was set to non-blocking for accept_with_timeout, and the
        // accepted stream inherits that mode. Switch it back to blocking so that
        // DAP message reads wait for data instead of returning EAGAIN/WouldBlock.
        stream
            .set_nonblocking(false)
            .map_err(|e| format!("failed to set stream to blocking: {}", e))?;

        let reader = BufReader::new(stream.try_clone().unwrap());
        let writer = stream;

        Ok(DapTestClient {
            client: DapClient::default(),
            reader,
            writer,
            db_backend,
            _listener: listener,
        })
    }

    /// Initialize the DAP session and launch with a recording
    pub fn initialize_and_launch(&mut self, recording: &TestRecording, ct_rr_support: &Path) -> Result<(), String> {
        // Send initialize
        let init = self.client.request("initialize", json!({}));
        self.send(&init)?;
        self.read_until_response("initialize", Duration::from_secs(5))?;

        // Send configurationDone
        let conf_done = self.client.request("configurationDone", json!({}));
        self.send(&conf_done)?;

        // Send launch
        let launch_args = LaunchRequestArguments {
            program: None,
            trace_folder: Some(recording.trace_dir.clone()),
            trace_file: None,
            raw_diff_index: None,
            pid: None,
            cwd: None,
            no_debug: None,
            restart: None,
            name: None,
            request: None,
            typ: None,
            session_id: None,
            recreator_exe: Some(ct_rr_support.to_path_buf()),
            restore_location: None,
        };
        let launch = self
            .client
            .launch(launch_args)
            .map_err(|e| format!("failed to build launch: {}", e))?;
        self.send(&launch)?;

        // Wait for stopped event (entry point)
        self.read_until_event("stopped", Duration::from_secs(30))?;
        // Consume the complete-move event
        self.read_until_event("ct/complete-move", Duration::from_secs(5))?;

        Ok(())
    }

    /// Set a breakpoint at the given line
    pub fn set_breakpoint(&mut self, source_path: &Path, line: u32) -> Result<(), String> {
        let set_bp = self.client.request(
            "setBreakpoints",
            json!({
                "source": {
                    "path": source_path.to_str().unwrap()
                },
                "breakpoints": [
                    { "line": line }
                ]
            }),
        );
        self.send(&set_bp)?;
        self.read_until_response("setBreakpoints", Duration::from_secs(5))?;
        Ok(())
    }

    /// Continue execution and wait for stopped event
    pub fn continue_to_breakpoint(&mut self) -> Result<Location, String> {
        let continue_req = self.client.request("continue", json!({ "threadId": 1 }));
        self.send(&continue_req)?;

        // Wait for stopped event
        self.read_until_event("stopped", Duration::from_secs(30))?;

        // Wait for complete-move event to get location
        let complete_move = self.read_until_event("ct/complete-move", Duration::from_secs(5))?;

        match complete_move {
            DapMessage::Event(e) => serde_json::from_value(e.body["location"].clone())
                .map_err(|e| format!("failed to parse location: {}", e)),
            _ => Err("expected event".to_string()),
        }
    }

    /// Request flow data for a location
    pub fn request_flow(&mut self, location: Location) -> Result<FlowData, String> {
        let flow_args = CtLoadFlowArguments {
            flow_mode: FlowMode::Call,
            location,
        };
        let flow_req = self
            .client
            .request("ct/load-flow", serde_json::to_value(flow_args).unwrap());
        self.send(&flow_req)?;

        // Wait for flow update event
        let flow_update = self.read_until_event("ct/updated-flow", Duration::from_secs(30))?;

        match flow_update {
            DapMessage::Event(e) => FlowData::from_event_body(&e.body),
            _ => Err("expected event".to_string()),
        }
    }

    fn send(&mut self, msg: &DapMessage) -> Result<(), String> {
        self.writer.send(msg).map_err(|e| format!("failed to send: {}", e))
    }

    fn read_until_event(&mut self, event_name: &str, timeout: Duration) -> Result<DapMessage, String> {
        let start = Instant::now();
        loop {
            if start.elapsed() >= timeout {
                return Err(format!("timeout waiting for event '{}'", event_name));
            }

            match dap::read_dap_message_from_reader(&mut self.reader) {
                Ok(msg) => {
                    if let DapMessage::Event(ref e) = msg {
                        if e.event == event_name {
                            return Ok(msg);
                        }
                    }
                }
                Err(e) => {
                    return Err(format!("error reading message: {}", e));
                }
            }
        }
    }

    fn read_until_response(&mut self, command: &str, timeout: Duration) -> Result<DapMessage, String> {
        let start = Instant::now();
        loop {
            if start.elapsed() >= timeout {
                return Err(format!("timeout waiting for response to '{}'", command));
            }

            match dap::read_dap_message_from_reader(&mut self.reader) {
                Ok(msg) => {
                    if let DapMessage::Response(ref r) = msg {
                        if r.command == command {
                            return Ok(msg);
                        }
                    }
                }
                Err(e) => {
                    return Err(format!("error reading message: {}", e));
                }
            }
        }
    }
}

#[cfg(unix)]
impl Drop for DapTestClient {
    fn drop(&mut self) {
        self.db_backend.kill().ok();
        // Capture and print stderr for debugging test failures
        if let Some(stderr) = self.db_backend.stderr.take() {
            use std::io::Read as _;
            let mut buf = String::new();
            let mut stderr = stderr;
            stderr.read_to_string(&mut buf).ok();
            if !buf.is_empty() {
                eprintln!("\n=== db-backend stderr ===\n{}\n=== end db-backend stderr ===", buf);
            }
        }
        self.db_backend.wait().ok();
    }
}

/// A cross-platform DAP test client that communicates over stdio (stdin/stdout pipes).
///
/// This avoids Unix domain sockets entirely, making it usable on Windows. The child
/// process is `db-backend dap-server --stdio`. A background thread reads stdout and
/// sends parsed `DapMessage`s through an `mpsc` channel so the main thread can
/// wait with timeouts.
pub struct DapStdioTestClient {
    child: Child,
    reader_rx: Receiver<Result<DapMessage, String>>,
    writer: ChildStdin,
    client: DapClient,
}

impl DapStdioTestClient {
    /// Spawn `db-backend dap-server --stdio` and set up pipes.
    pub fn start() -> Result<Self, String> {
        let db_backend_bin = env!("CARGO_BIN_EXE_replay-server");
        let mut child = Command::new(db_backend_bin)
            .arg("dap-server")
            .arg("--stdio")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("failed to spawn db-backend dap-server --stdio: {}", e))?;

        let writer = child
            .stdin
            .take()
            .ok_or_else(|| "failed to capture db-backend stdin".to_string())?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| "failed to capture db-backend stdout".to_string())?;
        let (reader_tx, reader_rx) = mpsc::channel::<Result<DapMessage, String>>();
        thread::spawn(move || {
            let mut reader = BufReader::new(stdout);
            loop {
                match dap::read_dap_message_from_reader(&mut reader) {
                    Ok(msg) => {
                        if reader_tx.send(Ok(msg)).is_err() {
                            break;
                        }
                    }
                    Err(err) => {
                        let _ = reader_tx.send(Err(format!("error reading DAP message: {}", err)));
                        break;
                    }
                }
            }
        });

        Ok(DapStdioTestClient {
            child,
            reader_rx,
            writer,
            client: DapClient::default(),
        })
    }

    /// Initialize the DAP session and launch with an RR/TTD recording.
    ///
    /// Unlike `initialize_and_launch()` (for DB traces), this passes the
    /// `recreator_exe` so the backend can spawn the replay worker.
    pub fn initialize_and_launch_rr(&mut self, recording: &TestRecording, ct_rr_support: &Path) -> Result<(), String> {
        // Send initialize
        let init = self.client.request("initialize", json!({}));
        self.send(&init)?;
        self.read_until_response("initialize", Duration::from_secs(5))?;

        // Wait for initialized event
        self.read_until_event("initialized", Duration::from_secs(5))?;

        // Send configurationDone
        let conf_done = self.client.request("configurationDone", json!({}));
        self.send(&conf_done)?;

        // Send launch with recreator_exe
        let launch_args = LaunchRequestArguments {
            program: None,
            trace_folder: Some(recording.trace_dir.clone()),
            trace_file: None,
            raw_diff_index: None,
            pid: None,
            cwd: None,
            no_debug: None,
            restart: None,
            name: None,
            request: None,
            typ: None,
            session_id: None,
            recreator_exe: Some(ct_rr_support.to_path_buf()),
            restore_location: None,
        };
        let launch = self
            .client
            .launch(launch_args)
            .map_err(|e| format!("failed to build launch: {}", e))?;
        self.send(&launch)?;

        // Wait for stopped event (entry point)
        self.read_until_event("stopped", Duration::from_secs(30))?;
        // Consume the complete-move event
        self.read_until_event("ct/complete-move", Duration::from_secs(5))?;

        Ok(())
    }

    /// Initialize the DAP session and launch with a recording (DB-trace variant).
    pub fn initialize_and_launch(&mut self, recording: &TestRecording) -> Result<(), String> {
        // Send initialize
        let init = self.client.request("initialize", json!({}));
        self.send(&init)?;
        self.read_until_response("initialize", Duration::from_secs(5))?;

        // Wait for initialized event
        self.read_until_event("initialized", Duration::from_secs(5))?;

        // Send configurationDone
        let conf_done = self.client.request("configurationDone", json!({}));
        self.send(&conf_done)?;

        // Send launch — recreator_exe must be None for DB traces so that
        // db-backend does not attempt to start an rr replay worker.
        let launch_args = LaunchRequestArguments {
            program: None,
            trace_folder: Some(recording.trace_dir.clone()),
            trace_file: None,
            raw_diff_index: None,
            pid: None,
            cwd: None,
            no_debug: None,
            restart: None,
            name: None,
            request: None,
            typ: None,
            session_id: None,
            recreator_exe: None,
            restore_location: None,
        };
        let launch = self
            .client
            .launch(launch_args)
            .map_err(|e| format!("failed to build launch: {}", e))?;
        self.send(&launch)?;

        // Wait for stopped event (entry point)
        self.read_until_event("stopped", Duration::from_secs(30))?;
        // Consume the complete-move event
        self.read_until_event("ct/complete-move", Duration::from_secs(5))?;

        Ok(())
    }

    /// Set a breakpoint at the given line
    pub fn set_breakpoint(&mut self, source_path: &Path, line: u32) -> Result<(), String> {
        let set_bp = self.client.request(
            "setBreakpoints",
            json!({
                "source": {
                    "path": source_path.to_str().unwrap()
                },
                "breakpoints": [
                    { "line": line }
                ]
            }),
        );
        self.send(&set_bp)?;
        self.read_until_response("setBreakpoints", Duration::from_secs(5))?;
        Ok(())
    }

    /// Continue execution and wait for stopped event
    pub fn continue_to_breakpoint(&mut self) -> Result<Location, String> {
        let continue_req = self.client.request("continue", json!({ "threadId": 1 }));
        self.send(&continue_req)?;

        // Wait for stopped event
        self.read_until_event("stopped", Duration::from_secs(30))?;

        // Wait for complete-move event to get location
        let complete_move = self.read_until_event("ct/complete-move", Duration::from_secs(5))?;

        match complete_move {
            DapMessage::Event(e) => serde_json::from_value(e.body["location"].clone())
                .map_err(|e| format!("failed to parse location: {}", e)),
            _ => Err("expected event".to_string()),
        }
    }

    /// Request flow data for a location
    pub fn request_flow(&mut self, location: Location) -> Result<FlowData, String> {
        let flow_args = CtLoadFlowArguments {
            flow_mode: FlowMode::Call,
            location,
        };
        let flow_req = self
            .client
            .request("ct/load-flow", serde_json::to_value(flow_args).unwrap());
        self.send(&flow_req)?;

        // Wait for flow update event
        let flow_update = self.read_until_event("ct/updated-flow", Duration::from_secs(30))?;

        match flow_update {
            DapMessage::Event(e) => FlowData::from_event_body(&e.body),
            _ => Err("expected event".to_string()),
        }
    }

    fn send(&mut self, msg: &DapMessage) -> Result<(), String> {
        self.writer.send(msg).map_err(|e| format!("failed to send: {}", e))
    }

    fn read_next(&mut self, timeout: Duration) -> Result<DapMessage, String> {
        match self.reader_rx.recv_timeout(timeout) {
            Ok(Ok(msg)) => Ok(msg),
            Ok(Err(err)) => Err(err),
            Err(RecvTimeoutError::Timeout) => Err(format!("timed out waiting for DAP message after {:?}", timeout)),
            Err(RecvTimeoutError::Disconnected) => {
                Err("DAP reader thread disconnected before delivering a message".to_string())
            }
        }
    }

    fn read_until_event(&mut self, event_name: &str, timeout: Duration) -> Result<DapMessage, String> {
        let start = Instant::now();
        loop {
            let remaining = timeout.saturating_sub(start.elapsed());
            if remaining.is_zero() {
                return Err(format!("timeout waiting for event '{}'", event_name));
            }

            let msg = self.read_next(remaining)?;
            if let DapMessage::Event(ref e) = msg {
                if e.event == event_name {
                    return Ok(msg);
                }
            }
        }
    }

    fn read_until_response(&mut self, command: &str, timeout: Duration) -> Result<DapMessage, String> {
        let start = Instant::now();
        loop {
            let remaining = timeout.saturating_sub(start.elapsed());
            if remaining.is_zero() {
                return Err(format!("timeout waiting for response to '{}'", command));
            }

            let msg = self.read_next(remaining)?;
            if let DapMessage::Response(ref r) = msg {
                if r.command == command {
                    return Ok(msg);
                }
            }
        }
    }
}

impl Drop for DapStdioTestClient {
    fn drop(&mut self) {
        self.child.kill().ok();
        // Capture and print stderr for debugging test failures
        if let Some(stderr) = self.child.stderr.take() {
            use std::io::Read as _;
            let mut buf = String::new();
            let mut stderr = stderr;
            stderr.read_to_string(&mut buf).ok();
            if !buf.is_empty() {
                eprintln!("\n=== db-backend stderr ===\n{}\n=== end db-backend stderr ===", buf);
            }
        }
        self.child.wait().ok();
    }
}

/// Parsed flow data from a flow update event
#[derive(Debug)]
pub struct FlowData {
    pub steps: Vec<FlowStep>,
    /// All variable names extracted (may contain duplicates)
    pub all_variables: Vec<String>,
    /// Map of variable name to its most recent value
    pub values: HashMap<String, serde_json::Value>,
}

#[derive(Debug)]
pub struct FlowStep {
    pub line: i64,
    pub variables: Vec<String>,
    pub before_values: HashMap<String, serde_json::Value>,
}

impl FlowData {
    fn from_event_body(body: &serde_json::Value) -> Result<Self, String> {
        let view_updates = body
            .get("viewUpdates")
            .and_then(|v| v.as_array())
            .ok_or("viewUpdates should exist")?;

        let first_update = view_updates.first().ok_or("should have at least one view update")?;

        let steps_json = first_update
            .get("steps")
            .and_then(|s| s.as_array())
            .ok_or("steps should exist")?;

        let mut steps = Vec::new();
        let mut all_variables = Vec::new();
        let mut values = HashMap::new();

        for step_json in steps_json {
            // Flow steps use "position" (from FlowStep.position: Position) in camelCase JSON.
            let line = step_json
                .get("position")
                .and_then(|l| l.as_i64())
                .or_else(|| step_json.get("line").and_then(|l| l.as_i64()))
                .unwrap_or(0);

            let mut variables = Vec::new();
            if let Some(expr_order) = step_json.get("exprOrder").and_then(|e| e.as_array()) {
                for expr in expr_order {
                    if let Some(var_name) = expr.as_str() {
                        variables.push(var_name.to_string());
                        all_variables.push(var_name.to_string());
                    }
                }
            }

            let mut before_values = HashMap::new();
            if let Some(bv) = step_json.get("beforeValues").and_then(|v| v.as_object()) {
                for (var_name, value) in bv {
                    before_values.insert(var_name.clone(), value.clone());
                    values.insert(var_name.clone(), value.clone());
                }
            }

            steps.push(FlowStep {
                line,
                variables,
                before_values,
            });
        }

        Ok(FlowData {
            steps,
            all_variables,
            values,
        })
    }

    /// Check if a value was successfully loaded (not <NONE>)
    pub fn is_value_loaded(value: &serde_json::Value) -> bool {
        if let Some(r_val) = value.get("r").and_then(|v| v.as_str()) {
            return r_val != "<NONE>";
        }
        false
    }

    /// Extract an integer value from a flow value structure
    pub fn extract_int_value(value: &serde_json::Value) -> Option<i64> {
        // The "i" field contains the integer value as a string
        if let Some(i_val) = value.get("i").and_then(|v| v.as_str()) {
            if !i_val.is_empty() {
                if let Ok(n) = i_val.parse::<i64>() {
                    return Some(n);
                }
            }
        }

        // The "r" field contains the raw result
        if let Some(r_val) = value.get("r").and_then(|v| v.as_str()) {
            if r_val != "<NONE>" && !r_val.is_empty() {
                if let Ok(n) = r_val.parse::<i64>() {
                    return Some(n);
                }
            }
        }

        None
    }

    /// Count loaded and unloaded values
    pub fn count_loaded(&self) -> (usize, usize) {
        let mut loaded = 0;
        let mut not_loaded = 0;
        for value in self.values.values() {
            if Self::is_value_loaded(value) {
                loaded += 1;
            } else {
                not_loaded += 1;
            }
        }
        (loaded, not_loaded)
    }
}

/// Configuration for a flow test case
pub struct FlowTestConfig {
    pub source_path: PathBuf,
    pub language: Language,
    pub breakpoint_line: u32,
    /// Variables that SHOULD be extracted (local vars, params)
    pub expected_variables: Vec<String>,
    /// Variables/identifiers that should NOT be extracted (function calls)
    pub excluded_identifiers: Vec<String>,
    /// Expected values for specific variables (name -> expected int value)
    pub expected_values: HashMap<String, i64>,
}

/// Look up a tool on the system PATH.
/// Uses `which` on Unix (already used by existing find_ct_native_replay and find_wazero).
fn find_on_path(name: &str) -> Option<PathBuf> {
    #[cfg(unix)]
    {
        if let Ok(output) = Command::new("which").arg(name).output() {
            if output.status.success() {
                let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
                if !path.is_empty() {
                    return Some(PathBuf::from(path));
                }
            }
        }
    }
    #[cfg(windows)]
    {
        if let Ok(output) = Command::new("where").arg(name).output() {
            if output.status.success() {
                let path = String::from_utf8_lossy(&output.stdout)
                    .lines()
                    .next()
                    .unwrap_or("")
                    .trim()
                    .to_string();
                if !path.is_empty() {
                    return Some(PathBuf::from(path));
                }
            }
        }
    }
    None
}

/// Find ct-native-replay binary (formerly ct-rr-support).
///
/// Search order:
/// 1. `CT_NATIVE_REPLAY_PATH` env var (explicit override),
///    falling back to legacy `CT_RR_SUPPORT_PATH`
/// 2. System PATH lookup (via `which`/`where`) for `ct-native-replay`,
///    falling back to legacy `ct-rr-support`
/// 3. Common development locations relative to CARGO_MANIFEST_DIR
/// 4. Home directory locations
pub fn find_ct_rr_support() -> Option<PathBuf> {
    // Highest priority: explicit env var override.
    // Used by cross-repo test scripts to communicate the binary location.
    for var_name in &["CT_NATIVE_REPLAY_PATH", "CT_RR_SUPPORT_PATH"] {
        if let Ok(path) = env::var(var_name) {
            let p = PathBuf::from(&path);
            if p.exists() && p.is_file() {
                return Some(p);
            }
            eprintln!("WARNING: {}='{}' but file does not exist; falling back", var_name, path);
        }
    }

    // Check PATH — try new name first, then legacy name
    for bin_name in &["ct-native-replay", "ct-rr-support"] {
        let exe_name = format!("{}{}", bin_name, std::env::consts::EXE_SUFFIX);
        if let Some(path) = find_on_path(&exe_name) {
            return Some(path);
        }
    }

    // Check common development locations (try both repo names)
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let new_exe = format!("ct-native-replay{}", std::env::consts::EXE_SUFFIX);
    let old_exe = format!("ct-rr-support{}", std::env::consts::EXE_SUFFIX);
    for exe_name in &[&new_exe, &old_exe] {
        let dev_locations = [
            format!("../../codetracer-native-backend/target/debug/{}", exe_name),
            format!("../../codetracer-native-backend/target/release/{}", exe_name),
            format!("../../../codetracer-native-backend/target/debug/{}", exe_name),
            // Legacy repo name fallbacks
            format!("../../codetracer-rr-backend/target/debug/{}", exe_name),
            format!("../../codetracer-rr-backend/target/release/{}", exe_name),
            format!("../../../codetracer-rr-backend/target/debug/{}", exe_name),
        ];

        for loc in &dev_locations {
            let path = manifest_dir.join(loc);
            if path.exists() {
                return Some(safe_canonicalize(&path));
            }
        }
    }

    // Check from home directory
    if let Some(home) = env::var_os("HOME").or_else(|| env::var_os("USERPROFILE")) {
        let home_path = PathBuf::from(home);
        for exe_name in &[&new_exe, &old_exe] {
            let home_locations = [
                format!("metacraft/codetracer-native-backend/target/debug/{}", exe_name),
                format!("codetracer-native-backend/target/debug/{}", exe_name),
                // Legacy repo name fallbacks
                format!("metacraft/codetracer-rr-backend/target/debug/{}", exe_name),
                format!("codetracer-rr-backend/target/debug/{}", exe_name),
            ];
            for loc in &home_locations {
                let path = home_path.join(loc);
                if path.exists() {
                    return Some(path);
                }
            }
        }
    }

    None
}

/// Check if rr is available (Unix only)
#[cfg(unix)]
pub fn is_rr_available() -> bool {
    Command::new("rr").arg("--version").output().is_ok()
}

/// Check if rr is available (always false on non-Unix)
#[cfg(not(unix))]
pub fn is_rr_available() -> bool {
    false
}

/// Check if TTD (Time Travel Debugging) is available (Windows only).
///
/// Checks that ct-native-replay is present, the Microsoft.TimeTravelDebugging
/// package is installed, AND the process is running elevated (Admin).
/// TTD recording requires elevation on Windows.
#[cfg(windows)]
pub fn is_ttd_available() -> bool {
    if find_ct_rr_support().is_none() {
        return false;
    }
    // Check if TTD package is installed via PowerShell
    let ttd_installed = Command::new("powershell")
        .args(["-NoProfile", "-Command",
            "if (Get-AppxPackage Microsoft.TimeTravelDebugging -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }"])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);
    if !ttd_installed {
        return false;
    }
    // TTD recording requires elevation (Administrator)
    is_elevated()
}

/// Check if the current process is running with elevated (Administrator) privileges.
#[cfg(windows)]
fn is_elevated() -> bool {
    Command::new("powershell")
        .args(["-NoProfile", "-Command",
            "if (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { exit 0 } else { exit 1 }"])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// TTD is not available on non-Windows platforms.
#[cfg(not(windows))]
pub fn is_ttd_available() -> bool {
    false
}

/// Check if the MCR recording backend is available.
///
/// MCR requires both `ct-native-replay` and `ct-mcr` to be on PATH.
pub fn is_mcr_available() -> bool {
    if find_ct_rr_support().is_none() {
        return false;
    }
    find_on_path("ct-mcr").is_some()
}

/// Check if a replay backend is available (rr on Unix, TTD on Windows).
pub fn is_replay_backend_available() -> bool {
    if cfg!(unix) {
        is_rr_available()
    } else {
        is_ttd_available()
    }
}

/// Accept a connection with timeout
#[cfg(unix)]
fn accept_with_timeout(
    listener: &UnixListener,
    timeout: Duration,
) -> io::Result<(UnixStream, std::os::unix::net::SocketAddr)> {
    listener.set_nonblocking(true)?;
    let start = Instant::now();
    loop {
        match listener.accept() {
            Ok(pair) => return Ok(pair),
            Err(ref e) if e.kind() == ErrorKind::WouldBlock => {
                if start.elapsed() >= timeout {
                    return Err(io::Error::new(ErrorKind::TimedOut, "accept timeout"));
                }
                thread::sleep(Duration::from_millis(20));
            }
            Err(e) => return Err(e),
        }
    }
}

/// Find the pure-Python recorder script (`trace.py`).
///
/// Search order:
/// 1. `CODETRACER_PYTHON_RECORDER_PATH` env var (explicit override)
/// 2. System PATH lookup for `trace.py` (for pip-installed recorder)
/// 3. Sibling repo: `../../../codetracer-python-recorder/codetracer-pure-python-recorder/src/trace.py`
/// 4. Legacy submodule: `../../libs/codetracer-python-recorder/codetracer-pure-python-recorder/src/trace.py`
///
/// Returns `None` if the recorder is not found.
pub fn find_python_recorder() -> Option<PathBuf> {
    if let Ok(path) = env::var("CODETRACER_PYTHON_RECORDER_PATH") {
        let p = PathBuf::from(&path);
        if p.exists() {
            return Some(p);
        }
        eprintln!(
            "WARNING: CODETRACER_PYTHON_RECORDER_PATH='{}' but file does not exist; falling back",
            path
        );
    }

    // Check PATH (for pip-installed recorder)
    if let Some(path) = find_on_path("trace.py") {
        return Some(path);
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let locations = [
        // Sibling repo (workspace layout)
        "../../../codetracer-python-recorder/codetracer-pure-python-recorder/src/trace.py",
        // Legacy submodule
        "../../libs/codetracer-python-recorder/codetracer-pure-python-recorder/src/trace.py",
    ];

    for loc in locations {
        let path = manifest_dir.join(loc);
        if path.exists() {
            return Some(safe_canonicalize(&path));
        }
    }

    None
}

/// Find a suitable Python 3.10+ interpreter for the recorder.
///
/// Returns the command name and version string, or `None` if no suitable
/// Python is available. The Python recorder uses PEP 604 union syntax
/// (`X | None`) which requires Python 3.10+.
pub fn find_suitable_python() -> Option<(String, String)> {
    use std::process::Command;

    let cmd = env::var("CODETRACER_PYTHON_CMD")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| {
            ["python3.12", "python3.13", "python3", "python"]
                .iter()
                .find(|c| {
                    Command::new(c)
                        .arg("--version")
                        .output()
                        .map(|o| o.status.success())
                        .unwrap_or(false)
                })
                .copied()
                .unwrap_or("python3")
                .to_string()
        });

    let version = Command::new(&cmd)
        .arg("--version")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|s| s.split_whitespace().nth(1).map(|v| v.to_string()))?;

    let parts: Vec<u32> = version.split('.').filter_map(|p| p.parse().ok()).collect();
    if parts.len() >= 2 && (parts[0] > 3 || (parts[0] == 3 && parts[1] >= 10)) {
        Some((cmd, version))
    } else {
        None
    }
}

/// Check if a command is available on PATH.
pub fn is_command_available(cmd: &str) -> bool {
    Command::new(cmd)
        .arg("--version")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// Source `scripts/detect-siblings.sh` and read back the named env var.
///
/// `detect-siblings.sh` knows how to locate sibling repos via repo-managed
/// workspace layouts, manifest files, env-var overrides, and relative paths.
/// We re-use that single source of truth so the test harness picks up the
/// same checkouts as `just`/Nix sees.
fn run_detect_siblings_for_var(var_name: &str) -> Option<PathBuf> {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let repo_root = manifest_dir.parent()?.parent()?;
    let detect_script = repo_root.join("scripts/detect-siblings.sh");
    if !detect_script.exists() {
        return None;
    }

    let script = format!(
        "DETECT_SIBLINGS_QUIET=1; source {:?} {:?} >/dev/null; printf '%s' \"${{{}:-}}\"",
        detect_script, repo_root, var_name
    );
    let output = Command::new("bash").arg("-lc").arg(script).output().ok()?;
    if !output.status.success() {
        return None;
    }
    let value = String::from_utf8(output.stdout).ok()?.trim().to_string();
    if value.is_empty() {
        return None;
    }
    let path = PathBuf::from(value);
    path.exists().then(|| safe_canonicalize(&path))
}

/// Find the codetracer-beam-recorder repo (records both Elixir and Erlang).
///
/// Search order:
/// 1. `CODETRACER_BEAM_RECORDER_PATH` env var (explicit repo override)
/// 2. `CODETRACER_ELIXIR_RECORDER_PATH` env var (legacy alias kept during the
///    BEAM rename migration window — still honored if set, with a warning)
/// 3. `scripts/detect-siblings.sh` workspace scan
/// 4. Relative sibling fallback from `src/db-backend`
pub fn find_beam_recorder_repo() -> Option<PathBuf> {
    if let Ok(path) = env::var("CODETRACER_BEAM_RECORDER_PATH") {
        let p = PathBuf::from(&path);
        if p.is_dir() {
            return Some(safe_canonicalize(&p));
        }
        eprintln!(
            "WARNING: CODETRACER_BEAM_RECORDER_PATH='{}' but directory does not exist; falling back",
            path
        );
    }

    // Legacy alias: pre-2026-05 the recorder lived in codetracer-elixir-recorder.
    // Honor the old env var so existing CI shims keep working during the
    // migration window. Drop in a follow-up release.
    if let Ok(path) = env::var("CODETRACER_ELIXIR_RECORDER_PATH") {
        let p = PathBuf::from(&path);
        if p.is_dir() {
            eprintln!("NOTE: CODETRACER_ELIXIR_RECORDER_PATH is deprecated; use CODETRACER_BEAM_RECORDER_PATH");
            return Some(safe_canonicalize(&p));
        }
    }

    if let Some(path) = run_detect_siblings_for_var("CODETRACER_BEAM_RECORDER_PATH") {
        return Some(path);
    }
    if let Some(path) = run_detect_siblings_for_var("CODETRACER_ELIXIR_RECORDER_PATH") {
        return Some(path);
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    for candidate in [
        manifest_dir.join("../../../codetracer-beam-recorder"),
        manifest_dir.join("../../../codetracer-elixir-recorder"),
    ] {
        if candidate.join("test-programs/elixir").exists() || candidate.join("test-programs/erlang").exists() {
            return Some(safe_canonicalize(&candidate));
        }
    }
    None
}

/// Legacy alias preserved for any out-of-tree callers; new code should use
/// `find_beam_recorder_repo`.
pub fn find_elixir_recorder_repo() -> Option<PathBuf> {
    find_beam_recorder_repo()
}

/// Find the codetracer-beam-recorder binary.
///
/// `CODETRACER_BEAM_RECORDER_BIN` (or the legacy alias
/// `CODETRACER_ELIXIR_RECORDER_BIN`) overrides the binary. Otherwise the
/// binary is resolved under the detected recorder repo, preferring debug
/// builds for local test speed and release builds for CI/prebuilt checkouts.
pub fn find_beam_recorder() -> Option<PathBuf> {
    for env_var in ["CODETRACER_BEAM_RECORDER_BIN", "CODETRACER_ELIXIR_RECORDER_BIN"] {
        if let Ok(path) = env::var(env_var) {
            let p = PathBuf::from(&path);
            if p.is_file() {
                if env_var == "CODETRACER_ELIXIR_RECORDER_BIN" {
                    eprintln!("NOTE: CODETRACER_ELIXIR_RECORDER_BIN is deprecated; use CODETRACER_BEAM_RECORDER_BIN");
                }
                return Some(safe_canonicalize(&p));
            }
            eprintln!("WARNING: {}='{}' but file does not exist; falling back", env_var, path);
        }
    }

    for binary_name in ["codetracer-beam-recorder", "codetracer-elixir-recorder"] {
        if let Some(path) = find_on_path(binary_name) {
            return Some(path);
        }
    }

    let repo = find_beam_recorder_repo()?;
    for binary_name in ["codetracer-beam-recorder", "codetracer-elixir-recorder"] {
        for profile in ["debug", "release"] {
            let candidate = repo.join(format!("target/{}/{}", profile, binary_name));
            if candidate.is_file() {
                return Some(safe_canonicalize(&candidate));
            }
        }
    }

    None
}

/// Legacy alias preserved for any out-of-tree callers; new code should use
/// `find_beam_recorder`.
pub fn find_elixir_recorder() -> Option<PathBuf> {
    find_beam_recorder()
}

/// Find the pure-Ruby recorder script.
///
/// Search order:
/// 1. `CODETRACER_RUBY_RECORDER_PATH` env var (explicit override)
/// 2. System PATH lookup for `codetracer-pure-ruby-recorder` (for gem-installed recorder)
/// 3. Sibling repo: `../../../codetracer-ruby-recorder/gems/codetracer-pure-ruby-recorder/bin/codetracer-pure-ruby-recorder`
/// 4. Legacy submodule: `../../libs/codetracer-ruby-recorder/gems/codetracer-pure-ruby-recorder/bin/codetracer-pure-ruby-recorder`
///
/// Returns `None` if the recorder is not found.
pub fn find_ruby_recorder() -> Option<PathBuf> {
    if let Ok(path) = env::var("CODETRACER_RUBY_RECORDER_PATH") {
        let p = PathBuf::from(&path);
        if p.exists() {
            return Some(p);
        }
        eprintln!(
            "WARNING: CODETRACER_RUBY_RECORDER_PATH='{}' but file does not exist; falling back",
            path
        );
    }

    // Check PATH (for gem-installed recorder)
    if let Some(path) = find_on_path("codetracer-pure-ruby-recorder") {
        return Some(path);
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let locations = [
        // Sibling repo (workspace layout)
        "../../../codetracer-ruby-recorder/gems/codetracer-pure-ruby-recorder/bin/codetracer-pure-ruby-recorder",
        // Legacy submodule
        "../../libs/codetracer-ruby-recorder/gems/codetracer-pure-ruby-recorder/bin/codetracer-pure-ruby-recorder",
    ];

    for loc in locations {
        let path = manifest_dir.join(loc);
        if path.exists() {
            return Some(safe_canonicalize(&path));
        }
    }

    None
}

/// Find the wazero binary for WASM recording.
///
/// Search order:
/// 1. `CODETRACER_WASM_VM_PATH` env var (explicit override)
/// 2. System PATH lookup (via `which`/`where`)
/// 3. Dev build locations relative to CARGO_MANIFEST_DIR
pub fn find_wazero() -> Option<PathBuf> {
    if let Ok(path) = env::var("CODETRACER_WASM_VM_PATH") {
        let p = PathBuf::from(&path);
        if p.exists() && p.is_file() {
            return Some(p);
        }
        eprintln!(
            "WARNING: CODETRACER_WASM_VM_PATH='{}' but file does not exist; falling back",
            path
        );
    }

    // Check PATH
    if let Some(path) = find_on_path("wazero") {
        return Some(path);
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let dev_locations = ["../../src/build-debug/bin/wazero", "../../result/bin/wazero"];
    for loc in dev_locations {
        let path = manifest_dir.join(loc);
        if path.exists() {
            return Some(safe_canonicalize(&path));
        }
    }

    None
}

/// Build a WASM test program from a Cargo project directory.
///
/// Runs `cargo build --target wasm32-wasip1` in debug mode (preserving DWARF).
/// Returns the path to the produced `.wasm` binary.
pub fn build_wasm_test_program(project_dir: &Path) -> Result<PathBuf, String> {
    let output = Command::new("cargo")
        .args(["build", "--target", "wasm32-wasip1"])
        .current_dir(project_dir)
        .output()
        .map_err(|e| format!("failed to run cargo build for WASM: {}", e))?;

    if !output.status.success() {
        return Err(format!(
            "WASM build failed:\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    // Find the produced .wasm binary
    let cargo_toml = project_dir.join("Cargo.toml");
    let cargo_content = fs::read_to_string(&cargo_toml).map_err(|e| format!("failed to read Cargo.toml: {}", e))?;

    // Extract package name from Cargo.toml
    let pkg_name = cargo_content
        .lines()
        .find(|l| l.starts_with("name"))
        .and_then(|l| l.split('=').nth(1))
        .map(|s| s.trim().trim_matches('"').to_string())
        .ok_or("failed to parse package name from Cargo.toml")?;

    let wasm_path = project_dir
        .join("target/wasm32-wasip1/debug")
        .join(format!("{}.wasm", pkg_name));

    if !wasm_path.exists() {
        return Err(format!("WASM binary not found at {}", wasm_path.display()));
    }

    Ok(wasm_path)
}

/// Record a WASM trace by running wazero.
///
/// Invokes `wazero run --out-dir <trace_dir> <wasm_path>`.
/// wazero stores absolute source paths in `trace_paths.json`.
fn record_wasm_trace(wasm_path: &Path, trace_dir: &Path) -> Result<(), String> {
    let wazero = find_wazero().ok_or("wazero not found; set CODETRACER_WASM_VM_PATH or add wazero to PATH")?;
    fs::create_dir_all(trace_dir).map_err(|e| format!("failed to create trace dir: {}", e))?;

    let output = Command::new(&wazero)
        .args([
            "run",
            "--out-dir",
            trace_dir.to_str().unwrap(),
            wasm_path.to_str().unwrap(),
        ])
        .output()
        .map_err(|e| format!("failed to run wazero: {}", e))?;

    if !output.status.success() {
        return Err(format!(
            "WASM recording failed:\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(())
}

/// Record a Stylus (Arbitrum WASM) trace by running wazero with the `-stylus` flag.
///
/// Unlike plain WASM recording, Stylus recording requires an EVM trace obtained
/// from `cargo stylus trace` after sending a transaction to a deployed contract.
/// The `-stylus` flag tells wazero to interpret the WASM in the context of the
/// Stylus EVM execution environment.
///
/// `evm_trace_path` must be a file path to a JSON file containing the EVM trace
/// (output of `cargo stylus trace`).
///
/// Invokes: `wazero run -stylus <evm_trace_path> --out-dir <trace_dir> <wasm_path>`.
pub fn record_stylus_wasm_trace(wasm_path: &Path, trace_dir: &Path, evm_trace_path: &Path) -> Result<(), String> {
    let wazero = find_wazero().ok_or("wazero not found; set CODETRACER_WASM_VM_PATH or add wazero to PATH")?;
    fs::create_dir_all(trace_dir).map_err(|e| format!("failed to create trace dir: {}", e))?;

    let output = Command::new(&wazero)
        .args([
            "run",
            "-stylus",
            evm_trace_path.to_str().unwrap(),
            "-out-dir",
            trace_dir.to_str().unwrap(),
            wasm_path.to_str().unwrap(),
        ])
        .output()
        .map_err(|e| format!("failed to run wazero with Stylus trace: {}", e))?;

    if !output.status.success() {
        return Err(format!(
            "Stylus WASM recording failed:\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(())
}

/// Record a Python trace by running the pure-Python recorder.
///
/// The recorder writes `trace.json`, `trace_metadata.json`, `trace_paths.json` to CWD,
/// so we set `current_dir` to `trace_dir`.
///
/// The recorder stores source paths as relative filenames (e.g. `python_flow_test.py`)
/// and sets `workdir` to CWD. The DAP server's ExprLoader resolves source files relative
/// to workdir, so we must copy the source file into the trace_dir to make it findable.
fn record_python_trace(source_path: &Path, trace_dir: &Path) -> Result<(), String> {
    record_python_trace_with_format(source_path, trace_dir, "binary")
}

/// Record a Python trace with the specified trace format.
///
/// Delegates to the pure-Python recorder, passing `CODETRACER_TRACE_FORMAT`
/// as an environment variable so the recorder can select the output format
/// (e.g. `"binary"` for CBOR+Zstd, `"ctfs"` for the `.ct` CTFS container).
fn record_python_trace_with_format(source_path: &Path, trace_dir: &Path, trace_format: &str) -> Result<(), String> {
    let recorder = find_python_recorder()
        .ok_or("Python recorder not found. Set CODETRACER_PYTHON_RECORDER_PATH or check out the sibling/submodule")?;
    fs::create_dir_all(trace_dir).map_err(|e| format!("failed to create trace dir: {}", e))?;

    // Pick a Python 3.10+ interpreter. Prefer CODETRACER_PYTHON_CMD (set by
    // detect-siblings.sh or the user), then try versioned brew binaries
    // (python3.12, python3.13), then the generic python3/python.
    let python = std::env::var("CODETRACER_PYTHON_CMD")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| {
            ["python3.12", "python3.13", "python3", "python"]
                .iter()
                .find(|cmd| {
                    Command::new(cmd)
                        .arg("--version")
                        .output()
                        .map(|o| o.status.success())
                        .unwrap_or(false)
                })
                .copied()
                .unwrap_or("python3")
                .to_string()
        });
    let output = Command::new(python)
        .args([recorder.to_str().unwrap(), source_path.to_str().unwrap()])
        .current_dir(trace_dir)
        .env("CODETRACER_TRACE_FORMAT", trace_format)
        .output()
        .map_err(|e| format!("failed to run Python recorder: {}", e))?;

    if !output.status.success() {
        return Err(format!(
            "Python recording failed:\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    // Copy source file into trace_dir so the DAP server can find it.
    // The recorder stores relative paths in trace_paths.json, and the server
    // resolves them against `workdir` (which is trace_dir).
    if let Some(filename) = source_path.file_name() {
        let dest = trace_dir.join(filename);
        if !dest.exists() {
            fs::copy(source_path, &dest).map_err(|e| format!("failed to copy source to trace dir: {}", e))?;
        }
    }

    Ok(())
}

/// Record a Ruby trace by running the pure-Ruby recorder.
///
/// Uses the same invocation pattern as `tracepoint_interpreter/tests.rs`:
/// `ruby <recorder> --out-dir <trace_dir> <source>` with `CODETRACER_DB_TRACE_PATH`.
fn record_ruby_trace(source_path: &Path, trace_dir: &Path) -> Result<(), String> {
    record_ruby_trace_with_format(source_path, trace_dir, "binary")
}

/// Record a Ruby trace with the specified trace format.
///
/// Delegates to the pure-Ruby recorder, passing `CODETRACER_TRACE_FORMAT`
/// as an environment variable so the recorder can select the output format.
fn record_ruby_trace_with_format(source_path: &Path, trace_dir: &Path, trace_format: &str) -> Result<(), String> {
    let recorder = find_ruby_recorder()
        .ok_or("Ruby recorder not found. Set CODETRACER_RUBY_RECORDER_PATH or check out the sibling/submodule")?;
    fs::create_dir_all(trace_dir).map_err(|e| format!("failed to create trace dir: {}", e))?;

    let trace_path = trace_dir.join("trace.json");
    let output = Command::new("ruby")
        .args([
            recorder.to_str().unwrap(),
            "--out-dir",
            trace_dir.to_str().unwrap(),
            source_path.to_str().unwrap(),
        ])
        .env("CODETRACER_DB_TRACE_PATH", trace_path.to_str().unwrap())
        .env("CODETRACER_TRACE_FORMAT", trace_format)
        .output()
        .map_err(|e| format!("failed to run Ruby recorder: {}", e))?;

    if !output.status.success() {
        return Err(format!(
            "Ruby recording failed:\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(())
}

/// Find the JavaScript recorder CLI entry point via CARGO_MANIFEST_DIR.
///
/// Search order:
/// 1. `CODETRACER_JS_RECORDER_PATH` env var (explicit override)
/// 2. System PATH lookup for `codetracer-js-recorder` (for npm-installed recorder)
/// 3. Sibling repo: `../../../codetracer-js-recorder/packages/cli/dist/index.js`
///
/// Returns `None` if the recorder is not found.
pub fn find_js_recorder() -> Option<PathBuf> {
    // Check explicit environment variable first
    if let Ok(path) = env::var("CODETRACER_JS_RECORDER_PATH") {
        let p = PathBuf::from(&path);
        if p.exists() {
            return Some(p);
        }
        eprintln!(
            "WARNING: CODETRACER_JS_RECORDER_PATH='{}' but file does not exist; falling back",
            path
        );
    }

    // Check PATH (for npm-installed recorder)
    if let Some(path) = find_on_path("codetracer-js-recorder") {
        return Some(path);
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let recorder = manifest_dir.join("../../../codetracer-js-recorder/packages/cli/dist/index.js");
    if recorder.exists() {
        Some(safe_canonicalize(&recorder))
    } else {
        None
    }
}

/// Record a JavaScript trace by running the JS recorder CLI.
///
/// Uses `node <cli> record <source> --format json --out-dir <tmp>`.
/// The recorder creates a `trace-N` subdirectory inside the output dir,
/// so after recording we find that subdirectory and rename it to `trace_dir`.
///
/// The recorder stores absolute source paths in the manifest, so suffix-matching works.
fn record_javascript_trace(source_path: &Path, trace_dir: &Path) -> Result<(), String> {
    let recorder = find_js_recorder()
        .ok_or("JavaScript recorder not found. Set CODETRACER_JS_RECORDER_PATH or build codetracer-js-recorder")?;

    // The JS recorder creates a trace-N subdirectory inside --out-dir.
    // Use a temporary output directory, then rename the subdirectory to trace_dir.
    let out_parent = trace_dir.parent().unwrap_or(trace_dir);
    let recorder_out = out_parent.join("js-recorder-out");
    fs::create_dir_all(&recorder_out).map_err(|e| format!("failed to create recorder out dir: {}", e))?;

    let output = Command::new("node")
        .args([
            recorder.to_str().unwrap(),
            "record",
            source_path.to_str().unwrap(),
            "--format",
            "binary",
            "--out-dir",
            recorder_out.to_str().unwrap(),
        ])
        .output()
        .map_err(|e| format!("failed to run JavaScript recorder: {}", e))?;

    if !output.status.success() {
        return Err(format!(
            "JavaScript recording failed:\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    // Find the generated trace-* subdirectory and rename it to the expected trace_dir
    let trace_subdir = fs::read_dir(&recorder_out)
        .map_err(|e| format!("failed to read recorder output: {}", e))?
        .filter_map(|e| e.ok())
        .find(|e| e.path().is_dir() && e.file_name().to_str().is_some_and(|n| n.starts_with("trace-")))
        .ok_or("no trace-* directory found in recorder output")?;

    fs::rename(trace_subdir.path(), trace_dir).map_err(|e| format!("failed to rename trace dir: {}", e))?;

    // Clean up the temporary output directory
    fs::remove_dir_all(&recorder_out).ok();

    Ok(())
}

/// Find the Bash recorder launcher script.
///
/// Search order:
/// 1. `CODETRACER_BASH_RECORDER_PATH` env var (explicit override)
/// 2. System PATH lookup for `codetracer-bash-recorder`
/// 3. Sibling repo: `../../../codetracer-shell-recorders/bash-recorder/launcher.sh`
///
/// Returns `None` if the recorder is not found.
pub fn find_bash_recorder() -> Option<PathBuf> {
    if let Ok(path) = env::var("CODETRACER_BASH_RECORDER_PATH") {
        let p = PathBuf::from(&path);
        if p.exists() {
            return Some(p);
        }
        eprintln!(
            "WARNING: CODETRACER_BASH_RECORDER_PATH='{}' but file does not exist; falling back",
            path
        );
    }

    // Check PATH
    if let Some(path) = find_on_path("codetracer-bash-recorder") {
        return Some(path);
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let recorder = manifest_dir.join("../../../codetracer-shell-recorders/bash-recorder/launcher.sh");
    if recorder.exists() {
        Some(safe_canonicalize(&recorder))
    } else {
        None
    }
}

/// Find the Zsh recorder launcher script.
///
/// Search order:
/// 1. `CODETRACER_ZSH_RECORDER_PATH` env var (explicit override)
/// 2. System PATH lookup for `codetracer-zsh-recorder`
/// 3. Sibling repo: `../../../codetracer-shell-recorders/zsh-recorder/launcher.zsh`
///
/// Returns `None` if the recorder is not found.
pub fn find_zsh_recorder() -> Option<PathBuf> {
    if let Ok(path) = env::var("CODETRACER_ZSH_RECORDER_PATH") {
        let p = PathBuf::from(&path);
        if p.exists() {
            return Some(p);
        }
        eprintln!(
            "WARNING: CODETRACER_ZSH_RECORDER_PATH='{}' but file does not exist; falling back",
            path
        );
    }

    // Check PATH
    if let Some(path) = find_on_path("codetracer-zsh-recorder") {
        return Some(path);
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let recorder = manifest_dir.join("../../../codetracer-shell-recorders/zsh-recorder/launcher.zsh");
    if recorder.exists() {
        Some(safe_canonicalize(&recorder))
    } else {
        None
    }
}

/// Find the codetracer-evm-recorder binary.
///
/// Search order:
/// 1. `CODETRACER_EVM_RECORDER_PATH` env var (explicit override)
/// 2. Sibling repo debug build:
///    `../../../codetracer-evm-recorder/target/debug/codetracer-evm-recorder`
///
/// Returns `None` if the recorder binary is not found.
///
/// Note: the EVM recorder records Solidity/EVM execution traces from transactions
/// against a running local blockchain node (e.g. Anvil/Hardhat). It requires
/// `solc` (Solidity compiler) and a running node to be available at recording time.
pub fn find_evm_recorder() -> Option<PathBuf> {
    if let Ok(path) = env::var("CODETRACER_EVM_RECORDER_PATH") {
        let p = PathBuf::from(&path);
        if p.exists() {
            return Some(p);
        }
        eprintln!(
            "WARNING: CODETRACER_EVM_RECORDER_PATH='{}' but file does not exist; falling back",
            path
        );
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    // Sibling repo (workspace layout) — debug build produced by `cargo build`
    let sibling = manifest_dir.join("../../../codetracer-evm-recorder/target/debug/codetracer-evm-recorder");
    if sibling.exists() {
        return Some(safe_canonicalize(&sibling));
    }

    None
}

/// Locate the Miden recorder binary (`codetracer-miden-recorder`).
///
/// Search order:
/// 1. `CODETRACER_MIDEN_RECORDER_PATH` env var (explicit override)
/// 2. Sibling repo debug build:
///    `../../../codetracer-miden-recorder/target/debug/codetracer-miden-recorder`
///
/// Returns `None` if the recorder binary is not found.
pub fn find_miden_recorder() -> Option<PathBuf> {
    if let Ok(path) = env::var("CODETRACER_MIDEN_RECORDER_PATH") {
        let p = PathBuf::from(&path);
        if p.exists() {
            return Some(p);
        }
        eprintln!(
            "WARNING: CODETRACER_MIDEN_RECORDER_PATH='{}' but file does not exist; falling back",
            path
        );
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let sibling = manifest_dir.join("../../../codetracer-miden-recorder/target/debug/codetracer-miden-recorder");
    if sibling.exists() {
        return Some(safe_canonicalize(&sibling));
    }

    None
}

/// Locate the Fuel recorder binary (`codetracer-fuel-recorder`).
///
/// Search order:
/// 1. `CODETRACER_FUEL_RECORDER_PATH` env var (explicit override)
/// 2. Sibling repo debug build:
///    `../../../codetracer-fuel-recorder/target/debug/codetracer-fuel-recorder`
///
/// Returns `None` if the recorder binary is not found.
pub fn find_fuel_recorder() -> Option<PathBuf> {
    if let Ok(path) = env::var("CODETRACER_FUEL_RECORDER_PATH") {
        let p = PathBuf::from(&path);
        if p.exists() {
            return Some(p);
        }
        eprintln!(
            "WARNING: CODETRACER_FUEL_RECORDER_PATH='{}' but file does not exist; falling back",
            path
        );
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let sibling = manifest_dir.join("../../../codetracer-fuel-recorder/target/debug/codetracer-fuel-recorder");
    if sibling.exists() {
        return Some(safe_canonicalize(&sibling));
    }

    None
}

/// Locate the Move recorder binary (`codetracer-move-recorder`).
///
/// Search order:
/// 1. `CODETRACER_MOVE_RECORDER_PATH` env var (explicit override)
/// 2. Sibling repo debug build:
///    `../../../codetracer-move-recorder/target/debug/codetracer-move-recorder`
///
/// Returns `None` if the recorder binary is not found.
pub fn find_move_recorder() -> Option<PathBuf> {
    if let Ok(path) = env::var("CODETRACER_MOVE_RECORDER_PATH") {
        let p = PathBuf::from(&path);
        if p.exists() {
            return Some(p);
        }
        eprintln!(
            "WARNING: CODETRACER_MOVE_RECORDER_PATH='{}' but file does not exist; falling back",
            path
        );
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let sibling = manifest_dir.join("../../../codetracer-move-recorder/target/debug/codetracer-move-recorder");
    if sibling.exists() {
        return Some(safe_canonicalize(&sibling));
    }

    None
}

/// Locate the Solana recorder binary (`codetracer-solana-recorder`).
///
/// Search order:
/// 1. `CODETRACER_SOLANA_RECORDER_PATH` env var (explicit override)
/// 2. Sibling repo debug build:
///    `../../../codetracer-solana-recorder/target/debug/codetracer-solana-recorder`
///
/// Returns `None` if the recorder binary is not found.
pub fn find_solana_recorder() -> Option<PathBuf> {
    if let Ok(path) = env::var("CODETRACER_SOLANA_RECORDER_PATH") {
        let p = PathBuf::from(&path);
        if p.exists() {
            return Some(p);
        }
        eprintln!(
            "WARNING: CODETRACER_SOLANA_RECORDER_PATH='{}' but file does not exist; falling back",
            path
        );
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let sibling = manifest_dir.join("../../../codetracer-solana-recorder/target/debug/codetracer-solana-recorder");
    if sibling.exists() {
        return Some(safe_canonicalize(&sibling));
    }

    None
}

/// Locate the PolkaVM recorder binary (`codetracer-polkavm-recorder`).
///
/// Search order:
/// 1. `CODETRACER_POLKAVM_RECORDER_PATH` env var (explicit override)
/// 2. Sibling repo debug build:
///    `../../../codetracer-polkavm-recorder/target/debug/codetracer-polkavm-recorder`
///
/// Returns `None` if the recorder binary is not found.
pub fn find_polkavm_recorder() -> Option<PathBuf> {
    if let Ok(path) = env::var("CODETRACER_POLKAVM_RECORDER_PATH") {
        let p = PathBuf::from(&path);
        if p.exists() {
            return Some(p);
        }
        eprintln!(
            "WARNING: CODETRACER_POLKAVM_RECORDER_PATH='{}' but file does not exist; falling back",
            path
        );
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let sibling = manifest_dir.join("../../../codetracer-polkavm-recorder/target/debug/codetracer-polkavm-recorder");
    if sibling.exists() {
        return Some(safe_canonicalize(&sibling));
    }

    None
}

/// Locate the Cairo recorder binary (`codetracer-cairo-recorder`).
///
/// Search order:
/// 1. `CODETRACER_CAIRO_RECORDER_PATH` env var (explicit override)
/// 2. Sibling repo debug build:
///    `../../../codetracer-cairo-recorder/target/debug/codetracer-cairo-recorder`
///
/// Returns `None` if the recorder binary is not found.
pub fn find_cairo_recorder() -> Option<PathBuf> {
    if let Ok(path) = env::var("CODETRACER_CAIRO_RECORDER_PATH") {
        let p = PathBuf::from(&path);
        if p.exists() {
            return Some(p);
        }
        eprintln!(
            "WARNING: CODETRACER_CAIRO_RECORDER_PATH='{}' but file does not exist; falling back",
            path
        );
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let sibling = manifest_dir.join("../../../codetracer-cairo-recorder/target/debug/codetracer-cairo-recorder");
    if sibling.exists() {
        return Some(safe_canonicalize(&sibling));
    }

    None
}

/// Locate the Circom recorder binary (`codetracer-circom-recorder`).
///
/// Search order:
/// 1. `CODETRACER_CIRCOM_RECORDER_PATH` env var (explicit override)
/// 2. Sibling repo release build:
///    `../../../codetracer-circom-recorder/target/release/codetracer-circom-recorder`
/// 3. Sibling repo debug build:
///    `../../../codetracer-circom-recorder/target/debug/codetracer-circom-recorder`
///
/// Returns `None` if the recorder binary is not found.
pub fn find_circom_recorder() -> Option<PathBuf> {
    if let Ok(path) = env::var("CODETRACER_CIRCOM_RECORDER_PATH") {
        let p = PathBuf::from(&path);
        if p.exists() {
            return Some(p);
        }
        eprintln!(
            "WARNING: CODETRACER_CIRCOM_RECORDER_PATH='{}' but file does not exist; falling back",
            path
        );
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    // Prefer release build (faster execution), fall back to debug.
    for profile in &["release", "debug"] {
        let sibling = manifest_dir.join(format!(
            "../../../codetracer-circom-recorder/target/{}/codetracer-circom-recorder",
            profile
        ));
        if sibling.exists() {
            return Some(safe_canonicalize(&sibling));
        }
    }

    None
}

/// Locate the Leo recorder binary (`codetracer-leo-recorder`).
///
/// Search order:
/// 1. `CODETRACER_LEO_RECORDER_PATH` env var (explicit override)
/// 2. Sibling repo debug build:
///    `../../../codetracer-leo-recorder/target/debug/codetracer-leo-recorder`
///
/// Returns `None` if the recorder binary is not found.
pub fn find_leo_recorder() -> Option<PathBuf> {
    if let Ok(path) = env::var("CODETRACER_LEO_RECORDER_PATH") {
        let p = PathBuf::from(&path);
        if p.exists() {
            return Some(p);
        }
        eprintln!(
            "WARNING: CODETRACER_LEO_RECORDER_PATH='{}' but file does not exist; falling back",
            path
        );
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let sibling = manifest_dir.join("../../../codetracer-leo-recorder/target/debug/codetracer-leo-recorder");
    if sibling.exists() {
        return Some(safe_canonicalize(&sibling));
    }

    None
}

/// Locate the Tolk/TON recorder binary (`codetracer-ton-recorder`).
///
/// Search order:
/// 1. `CODETRACER_TOLK_RECORDER_PATH` env var (explicit override)
/// 2. Sibling repo debug build:
///    `../../../codetracer-ton-recorder/target/debug/codetracer-ton-recorder`
///
/// Returns `None` if the recorder binary is not found.
pub fn find_tolk_recorder() -> Option<PathBuf> {
    if let Ok(path) = env::var("CODETRACER_TOLK_RECORDER_PATH") {
        let p = PathBuf::from(&path);
        if p.exists() {
            return Some(p);
        }
        eprintln!(
            "WARNING: CODETRACER_TOLK_RECORDER_PATH='{}' but file does not exist; falling back",
            path
        );
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let sibling = manifest_dir.join("../../../codetracer-ton-recorder/target/debug/codetracer-ton-recorder");
    if sibling.exists() {
        return Some(safe_canonicalize(&sibling));
    }

    None
}

/// Locate the Aiken/Cardano recorder binary (`codetracer-cardano-recorder`).
///
/// Search order:
/// 1. `CODETRACER_AIKEN_RECORDER_PATH` env var (explicit override)
/// 2. Sibling repo debug build:
///    `../../../codetracer-cardano-recorder/target/debug/codetracer-cardano-recorder`
///
/// Returns `None` if the recorder binary is not found.
pub fn find_aiken_recorder() -> Option<PathBuf> {
    if let Ok(path) = env::var("CODETRACER_AIKEN_RECORDER_PATH") {
        let p = PathBuf::from(&path);
        if p.exists() {
            return Some(p);
        }
        eprintln!(
            "WARNING: CODETRACER_AIKEN_RECORDER_PATH='{}' but file does not exist; falling back",
            path
        );
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let sibling = manifest_dir.join("../../../codetracer-cardano-recorder/target/debug/codetracer-cardano-recorder");
    if sibling.exists() {
        return Some(safe_canonicalize(&sibling));
    }

    None
}

/// Locate the Cadence/Flow recorder binary (`codetracer-flow-recorder`).
///
/// Search order:
/// 1. `CODETRACER_CADENCE_RECORDER_PATH` env var (explicit override)
/// 2. Sibling repo debug build:
///    `../../../codetracer-flow-recorder/target/debug/codetracer-flow-recorder`
///
/// Returns `None` if the recorder binary is not found.
pub fn find_cadence_recorder() -> Option<PathBuf> {
    if let Ok(path) = env::var("CODETRACER_CADENCE_RECORDER_PATH") {
        let p = PathBuf::from(&path);
        if p.exists() {
            return Some(p);
        }
        eprintln!(
            "WARNING: CODETRACER_CADENCE_RECORDER_PATH='{}' but file does not exist; falling back",
            path
        );
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let sibling = manifest_dir.join("../../../codetracer-flow-recorder/target/debug/codetracer-flow-recorder");
    if sibling.exists() {
        return Some(safe_canonicalize(&sibling));
    }

    None
}

// ---------------------------------------------------------------------------
// Test program discovery functions
//
// Per Test-Program-Layout.md, test programs live in their canonical recorder
// repos and are discovered via sibling repo paths. Returns None if the
// sibling repo is not checked out.
// ---------------------------------------------------------------------------

/// Locate the MASM flow test program from the sibling Miden recorder repo.
///
/// Canonical path: `codetracer-miden-recorder/test-programs/masm/masm_flow_test.masm`
pub fn find_masm_flow_test() -> Option<PathBuf> {
    if let Ok(path) = env::var("CODETRACER_MASM_FLOW_TEST") {
        let p = PathBuf::from(&path);
        if p.exists() {
            return Some(p);
        }
        eprintln!(
            "WARNING: CODETRACER_MASM_FLOW_TEST='{}' but file does not exist; falling back",
            path
        );
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let path = manifest_dir.join("../../../codetracer-miden-recorder/test-programs/masm/masm_flow_test.masm");
    if path.exists() {
        Some(safe_canonicalize(&path))
    } else {
        None
    }
}

/// Locate the Sway flow test project directory (containing `Forc.toml`)
/// from the sibling Fuel recorder repo.
///
/// Canonical path: `codetracer-fuel-recorder/test-programs/flow_test/`
pub fn find_sway_flow_test() -> Option<PathBuf> {
    if let Ok(path) = env::var("CODETRACER_SWAY_FLOW_TEST") {
        let p = PathBuf::from(&path);
        if p.exists() {
            return Some(p);
        }
        eprintln!(
            "WARNING: CODETRACER_SWAY_FLOW_TEST='{}' but path does not exist; falling back",
            path
        );
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let path = manifest_dir.join("../../../codetracer-fuel-recorder/test-programs/flow_test");
    if path.join("Forc.toml").exists() {
        Some(safe_canonicalize(&path))
    } else {
        None
    }
}

/// Locate the Sway flow test source file (`main.sw`) from the sibling
/// Fuel recorder repo.
pub fn find_sway_flow_source() -> Option<PathBuf> {
    if let Ok(path) = env::var("CODETRACER_SWAY_FLOW_SOURCE") {
        let p = PathBuf::from(&path);
        if p.exists() {
            return Some(p);
        }
        eprintln!(
            "WARNING: CODETRACER_SWAY_FLOW_SOURCE='{}' but file does not exist; falling back",
            path
        );
    }

    find_sway_flow_test().map(|project_dir| project_dir.join("src/main.sw"))
}

/// Locate the Move flow test project directory (containing `Move.toml`)
/// from the sibling Move recorder repo.
///
/// Canonical path: `codetracer-move-recorder/test-programs/move/flow_test/`
pub fn find_move_flow_test() -> Option<PathBuf> {
    if let Ok(path) = env::var("CODETRACER_MOVE_FLOW_TEST") {
        let p = PathBuf::from(&path);
        if p.exists() {
            return Some(p);
        }
        eprintln!(
            "WARNING: CODETRACER_MOVE_FLOW_TEST='{}' but path does not exist; falling back",
            path
        );
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let path = manifest_dir.join("../../../codetracer-move-recorder/test-programs/move/flow_test");
    if path.join("Move.toml").exists() {
        Some(safe_canonicalize(&path))
    } else {
        None
    }
}

/// Locate the Move flow test source file (`flow_test.move`) from the
/// sibling Move recorder repo.
pub fn find_move_flow_source() -> Option<PathBuf> {
    if let Ok(path) = env::var("CODETRACER_MOVE_FLOW_SOURCE") {
        let p = PathBuf::from(&path);
        if p.exists() {
            return Some(p);
        }
        eprintln!(
            "WARNING: CODETRACER_MOVE_FLOW_SOURCE='{}' but file does not exist; falling back",
            path
        );
    }

    find_move_flow_test().map(|project_dir| project_dir.join("sources/flow_test.move"))
}

/// Locate a specific Move trace file for a given test function name.
///
/// The Move test-programs directory contains pre-recorded trace files named
/// `flow_test__flow_test__<test_fn>.json.zst` inside the `traces/` subdirectory.
/// This function resolves the full path for a given test function name
/// (e.g. `"test_computation"` →
/// `.../flow_test/traces/flow_test__flow_test__test_computation.json.zst`).
pub fn find_move_trace_file(test_fn_name: &str) -> Option<PathBuf> {
    let project_dir = find_move_flow_test()?;
    let trace_file = project_dir.join(format!("traces/flow_test__flow_test__{}.json.zst", test_fn_name));
    if trace_file.exists() {
        Some(safe_canonicalize(&trace_file))
    } else {
        None
    }
}

/// Locate the Solana flow test source file from the sibling Solana
/// recorder repo.
///
/// Canonical path: `codetracer-solana-recorder/test-programs/solana/solana_flow_test.rs`
pub fn find_solana_flow_test() -> Option<PathBuf> {
    if let Ok(path) = env::var("CODETRACER_SOLANA_FLOW_TEST") {
        let p = PathBuf::from(&path);
        if p.exists() {
            return Some(p);
        }
        eprintln!(
            "WARNING: CODETRACER_SOLANA_FLOW_TEST='{}' but file does not exist; falling back",
            path
        );
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let path = manifest_dir.join("../../../codetracer-solana-recorder/test-programs/solana/solana_flow_test.rs");
    if path.exists() {
        Some(safe_canonicalize(&path))
    } else {
        None
    }
}

/// Locate the PolkaVM flow test blob from the sibling PolkaVM recorder repo.
///
/// Canonical path: `codetracer-polkavm-recorder/test-programs/rust/flow_test.polkavm`
///
/// The PolkaVM recorder expects a pre-compiled `.polkavm` blob, not a `.rs` source
/// file. The blob can be built by running:
///   `cargo run --example build_flow_test_blob`
/// inside the `codetracer-polkavm-recorder` repo.
pub fn find_polkavm_flow_test() -> Option<PathBuf> {
    if let Ok(path) = env::var("CODETRACER_POLKAVM_FLOW_TEST") {
        let p = PathBuf::from(&path);
        if p.exists() {
            return Some(p);
        }
        eprintln!(
            "WARNING: CODETRACER_POLKAVM_FLOW_TEST='{}' but file does not exist; falling back",
            path
        );
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));

    // Prefer the pre-compiled .polkavm blob (built via `cargo run --example build_flow_test_blob`).
    let blob_path = manifest_dir.join("../../../codetracer-polkavm-recorder/test-programs/rust/flow_test.polkavm");
    if blob_path.exists() {
        return Some(safe_canonicalize(&blob_path));
    }

    // Fall back to the .rs source. The caller (record_polkavm_trace) will detect
    // the .rs extension and attempt to build the blob automatically.
    let rs_path = manifest_dir.join("../../../codetracer-polkavm-recorder/test-programs/rust/flow_test.rs");
    if rs_path.exists() {
        Some(safe_canonicalize(&rs_path))
    } else {
        None
    }
}

/// Locate the Cairo flow test source file from the sibling Cairo recorder repo.
///
/// Canonical path: `codetracer-cairo-recorder/test-programs/cairo/flow_test.cairo`
pub fn find_cairo_flow_test() -> Option<PathBuf> {
    if let Ok(path) = env::var("CODETRACER_CAIRO_FLOW_TEST") {
        let p = PathBuf::from(&path);
        if p.exists() {
            return Some(p);
        }
        eprintln!(
            "WARNING: CODETRACER_CAIRO_FLOW_TEST='{}' but file does not exist; falling back",
            path
        );
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let path = manifest_dir.join("../../../codetracer-cairo-recorder/test-programs/cairo/flow_test.cairo");
    if path.exists() {
        Some(safe_canonicalize(&path))
    } else {
        None
    }
}

/// Locate the Circom flow test source file from the sibling Circom recorder repo.
///
/// Canonical path: `codetracer-circom-recorder/test-programs/circom/flow_test.circom`
pub fn find_circom_flow_test() -> Option<PathBuf> {
    if let Ok(path) = env::var("CODETRACER_CIRCOM_FLOW_TEST") {
        let p = PathBuf::from(&path);
        if p.exists() {
            return Some(p);
        }
        eprintln!(
            "WARNING: CODETRACER_CIRCOM_FLOW_TEST='{}' but file does not exist; falling back",
            path
        );
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let path = manifest_dir.join("../../../codetracer-circom-recorder/test-programs/circom/flow_test.circom");
    if path.exists() {
        Some(safe_canonicalize(&path))
    } else {
        None
    }
}

/// Locate the Leo flow test source file from the sibling Leo recorder repo.
///
/// Canonical path: `codetracer-leo-recorder/test-programs/leo/flow_test.leo`
pub fn find_leo_flow_test() -> Option<PathBuf> {
    if let Ok(path) = env::var("CODETRACER_LEO_FLOW_TEST") {
        let p = PathBuf::from(&path);
        if p.exists() {
            return Some(p);
        }
        eprintln!(
            "WARNING: CODETRACER_LEO_FLOW_TEST='{}' but file does not exist; falling back",
            path
        );
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let path = manifest_dir.join("../../../codetracer-leo-recorder/test-programs/leo/flow_test.leo");
    if path.exists() {
        Some(safe_canonicalize(&path))
    } else {
        None
    }
}

/// Locate the Tolk flow test source file from the sibling TON recorder repo.
///
/// Canonical path: `codetracer-ton-recorder/test-programs/tolk/flow_test.tolk`
pub fn find_tolk_flow_test() -> Option<PathBuf> {
    if let Ok(path) = env::var("CODETRACER_TOLK_FLOW_TEST") {
        let p = PathBuf::from(&path);
        if p.exists() {
            return Some(p);
        }
        eprintln!(
            "WARNING: CODETRACER_TOLK_FLOW_TEST='{}' but file does not exist; falling back",
            path
        );
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let path = manifest_dir.join("../../../codetracer-ton-recorder/test-programs/tolk/flow_test.tolk");
    if path.exists() {
        Some(safe_canonicalize(&path))
    } else {
        None
    }
}

/// Locate the Aiken flow test source file from the sibling Cardano recorder repo.
///
/// Canonical path: `codetracer-cardano-recorder/test-programs/aiken/flow_test.ak`
pub fn find_aiken_flow_test() -> Option<PathBuf> {
    if let Ok(path) = env::var("CODETRACER_AIKEN_FLOW_TEST") {
        let p = PathBuf::from(&path);
        if p.exists() {
            return Some(p);
        }
        eprintln!(
            "WARNING: CODETRACER_AIKEN_FLOW_TEST='{}' but file does not exist; falling back",
            path
        );
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let path = manifest_dir.join("../../../codetracer-cardano-recorder/test-programs/aiken/flow_test.ak");
    if path.exists() {
        Some(safe_canonicalize(&path))
    } else {
        None
    }
}

/// Locate the Cadence flow test source file from the sibling Flow recorder repo.
///
/// Canonical path: `codetracer-flow-recorder/test-programs/cadence/flow_test.cdc`
pub fn find_cadence_flow_test() -> Option<PathBuf> {
    if let Ok(path) = env::var("CODETRACER_CADENCE_FLOW_TEST") {
        let p = PathBuf::from(&path);
        if p.exists() {
            return Some(p);
        }
        eprintln!(
            "WARNING: CODETRACER_CADENCE_FLOW_TEST='{}' but file does not exist; falling back",
            path
        );
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let path = manifest_dir.join("../../../codetracer-flow-recorder/test-programs/cadence/flow_test.cdc");
    if path.exists() {
        Some(safe_canonicalize(&path))
    } else {
        None
    }
}

/// Locate the canonical Elixir flow Mix project from the sibling BEAM
/// recorder repo.
///
/// Canonical path:
/// `codetracer-beam-recorder/test-programs/elixir/canonical_flow/`
pub fn find_elixir_flow_test() -> Option<PathBuf> {
    if let Ok(path) = env::var("CODETRACER_ELIXIR_FLOW_TEST") {
        let p = PathBuf::from(&path);
        if p.join("mix.exs").exists() {
            return Some(safe_canonicalize(&p));
        }
        eprintln!(
            "WARNING: CODETRACER_ELIXIR_FLOW_TEST='{}' but Mix project does not exist; falling back",
            path
        );
    }

    let repo = find_beam_recorder_repo()?;
    let path = repo.join("test-programs/elixir/canonical_flow");
    if path.join("mix.exs").exists() {
        Some(safe_canonicalize(&path))
    } else {
        None
    }
}

/// Locate the canonical Erlang flow project from the sibling BEAM recorder
/// repo.
///
/// Canonical path:
/// `codetracer-beam-recorder/test-programs/erlang/canonical_flow/`
pub fn find_erlang_flow_test() -> Option<PathBuf> {
    if let Ok(path) = env::var("CODETRACER_ERLANG_FLOW_TEST") {
        let p = PathBuf::from(&path);
        if p.join("src/canonical_flow.erl").exists() {
            return Some(safe_canonicalize(&p));
        }
        eprintln!(
            "WARNING: CODETRACER_ERLANG_FLOW_TEST='{}' but Erlang project does not exist; falling back",
            path
        );
    }

    let repo = find_beam_recorder_repo()?;
    let path = repo.join("test-programs/erlang/canonical_flow");
    if path.join("src/canonical_flow.erl").exists() {
        Some(safe_canonicalize(&path))
    } else {
        None
    }
}

/// Record a Bash trace by running the shell recorder launcher.
///
/// Uses `bash <launcher.sh> --out-dir <trace_dir> --format binary <source>`.
fn record_bash_trace(source_path: &Path, trace_dir: &Path) -> Result<(), String> {
    let recorder = find_bash_recorder()
        .ok_or("Bash recorder not found. Set CODETRACER_BASH_RECORDER_PATH or check out codetracer-shell-recorders")?;

    // Build the trace writer binary first
    let shell_recorders_dir = recorder.parent().unwrap().parent().unwrap();
    let build_output = Command::new("cargo")
        .args(["build", "--release"])
        .current_dir(shell_recorders_dir)
        .output()
        .map_err(|e| format!("failed to build shell trace writer: {}", e))?;

    if !build_output.status.success() {
        return Err(format!(
            "Shell trace writer build failed:\nstderr: {}",
            String::from_utf8_lossy(&build_output.stderr)
        ));
    }

    fs::create_dir_all(trace_dir).map_err(|e| format!("failed to create trace dir: {}", e))?;

    let output = Command::new("bash")
        .args([
            recorder.to_str().unwrap(),
            "--out-dir",
            trace_dir.to_str().unwrap(),
            "--format",
            "binary",
            source_path.to_str().unwrap(),
        ])
        .output()
        .map_err(|e| format!("failed to run Bash recorder: {}", e))?;

    if !output.status.success() {
        return Err(format!(
            "Bash recording failed:\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(())
}

/// Record a Zsh trace by running the shell recorder launcher.
///
/// Uses `zsh <launcher.zsh> --out-dir <trace_dir> --format binary <source>`.
fn record_zsh_trace(source_path: &Path, trace_dir: &Path) -> Result<(), String> {
    let recorder = find_zsh_recorder()
        .ok_or("Zsh recorder not found. Set CODETRACER_ZSH_RECORDER_PATH or check out codetracer-shell-recorders")?;

    // Build the trace writer binary first (shared with Bash recorder)
    let shell_recorders_dir = recorder.parent().unwrap().parent().unwrap();
    let build_output = Command::new("cargo")
        .args(["build", "--release"])
        .current_dir(shell_recorders_dir)
        .output()
        .map_err(|e| format!("failed to build shell trace writer: {}", e))?;

    if !build_output.status.success() {
        return Err(format!(
            "Shell trace writer build failed:\nstderr: {}",
            String::from_utf8_lossy(&build_output.stderr)
        ));
    }

    fs::create_dir_all(trace_dir).map_err(|e| format!("failed to create trace dir: {}", e))?;

    let output = Command::new("zsh")
        .args([
            recorder.to_str().unwrap(),
            "--out-dir",
            trace_dir.to_str().unwrap(),
            "--format",
            "binary",
            source_path.to_str().unwrap(),
        ])
        .output()
        .map_err(|e| format!("failed to run Zsh recorder: {}", e))?;

    if !output.status.success() {
        return Err(format!(
            "Zsh recording failed:\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(())
}

/// Record a Noir trace by running `nargo trace` inside the Nargo project directory.
///
/// Unlike Python/Ruby where `source_path` is a single file, for Noir `source_path`
/// points to the project directory containing `Nargo.toml`. The `nargo trace` command
/// stores absolute source paths in `trace_paths.json`, so no source-file copying is
/// needed (unlike Python).
fn record_noir_trace(project_dir: &Path, trace_dir: &Path) -> Result<(), String> {
    fs::create_dir_all(trace_dir).map_err(|e| format!("failed to create trace dir: {}", e))?;

    // Give nargo its own temp directory to avoid "Directory not empty" races
    // when multiple Noir tests run in parallel or in sandboxed Nix builds
    // where stale temp dirs from previous builds may linger.
    let nargo_tmp = trace_dir.parent().unwrap_or(trace_dir).join("nargo_tmp");
    if nargo_tmp.exists() {
        let _ = fs::remove_dir_all(&nargo_tmp);
    }
    fs::create_dir_all(&nargo_tmp).map_err(|e| format!("failed to create nargo temp dir: {}", e))?;

    let output = Command::new("nargo")
        .args(["trace", "--out-dir", trace_dir.to_str().unwrap()])
        .current_dir(project_dir)
        .env("TMPDIR", &nargo_tmp)
        .output()
        .map_err(|e| format!("failed to run nargo trace: {}", e))?;

    if !output.status.success() {
        return Err(format!(
            "Noir recording failed:\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(())
}

/// Record a Solidity trace by invoking the `codetracer-evm-recorder record` CLI.
///
/// Runs:
///   `<evm-recorder> record <source.sol> --out-dir <trace_dir>`
///
/// The EVM recorder compiles the contract, deploys it to a temporary local
/// Anvil node, calls the default entry-point function (`run()`), fetches
/// `debug_traceTransaction` structlogs, and writes `trace.bin`,
/// `trace_metadata.json`, and `trace_paths.json` into `trace_dir`.
/// It also copies the source file into `trace_dir`.
///
/// Returns an error if the EVM recorder binary is not found, or if recording
/// fails for any reason.
fn record_solidity_trace(source_path: &Path, trace_dir: &Path) -> Result<(), String> {
    let recorder = find_evm_recorder().ok_or_else(|| {
        "EVM recorder not found. \
             Set CODETRACER_EVM_RECORDER_PATH or build codetracer-evm-recorder \
             (run `cargo build` inside the codetracer-evm-recorder repo)."
            .to_string()
    })?;

    // Resolve the EVM recorder repo directory from the binary location.
    // Binary is at <repo>/target/debug/codetracer-evm-recorder, so the repo
    // root is three levels up.
    let evm_recorder_dir = recorder.parent().and_then(|p| p.parent()).and_then(|p| p.parent());

    fs::create_dir_all(trace_dir).map_err(|e| format!("failed to create trace dir: {}", e))?;

    // The EVM recorder needs `solc` and `anvil` on PATH. These are provided
    // by the EVM recorder's Nix dev shell. When the repo directory is
    // available, we use `direnv exec` to enter that shell automatically.
    let output = if let Some(repo_dir) = evm_recorder_dir.filter(|d| d.join(".envrc").exists()) {
        Command::new("direnv")
            .args([
                "exec",
                repo_dir.to_str().unwrap(),
                recorder.to_str().unwrap(),
                "record",
                source_path.to_str().unwrap(),
                "--trace-dir",
                trace_dir.to_str().unwrap(),
            ])
            .output()
            .map_err(|e| format!("failed to run EVM recorder via direnv exec: {}", e))?
    } else {
        // Fall back to direct invocation (assumes solc/anvil are already on PATH)
        Command::new(&recorder)
            .args([
                "record",
                source_path.to_str().unwrap(),
                "--trace-dir",
                trace_dir.to_str().unwrap(),
            ])
            .output()
            .map_err(|e| format!("failed to run EVM recorder: {}", e))?
    };

    if !output.status.success() {
        return Err(format!(
            "EVM recorder failed:\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(())
}

/// Record a Miden/MASM trace by invoking the `codetracer-miden-recorder record` CLI.
///
/// Runs:
///   `<miden-recorder> record <source.masm> --out-dir <trace_dir>`
///
/// The Miden recorder executes the MASM program on the Miden VM, captures
/// step-by-step execution state (stack, locals, memory), and writes
/// `trace.bin`, `trace_metadata.json`, and `trace_paths.json` into `trace_dir`.
///
/// Returns an error if the recorder binary is not found, or if recording fails.
fn record_masm_trace(source_path: &Path, trace_dir: &Path) -> Result<(), String> {
    let recorder = find_miden_recorder().ok_or_else(|| {
        "Miden recorder not found. \
             Set CODETRACER_MIDEN_RECORDER_PATH or build codetracer-miden-recorder \
             (run `cargo build` inside the codetracer-miden-recorder repo)."
            .to_string()
    })?;

    fs::create_dir_all(trace_dir).map_err(|e| format!("failed to create trace dir: {}", e))?;

    let output = Command::new(&recorder)
        .args([
            "record",
            source_path.to_str().unwrap(),
            "--out-dir",
            trace_dir.to_str().unwrap(),
        ])
        .output()
        .map_err(|e| format!("failed to run Miden recorder: {}", e))?;

    if !output.status.success() {
        return Err(format!(
            "Miden recorder failed:\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(())
}

/// Record a Sway/FuelVM trace.
///
/// `source_path` is the Sway project directory (containing `Forc.toml`).
///
/// The pipeline has two steps:
///   1. Compile the project with `forc build` (via the fuel-recorder's dev shell)
///   2. Record the compiled bytecode: `<recorder> record --bytecode <.bin> --out-dir <trace_dir>`
///
/// The `forc build` output is at `<project>/out/debug/<project-name>.bin`.
fn record_fuel_trace(source_path: &Path, trace_dir: &Path) -> Result<(), String> {
    let recorder = find_fuel_recorder().ok_or_else(|| {
        "Fuel recorder not found. \
             Set CODETRACER_FUEL_RECORDER_PATH or build codetracer-fuel-recorder \
             (run `cargo build` inside the codetracer-fuel-recorder repo)."
            .to_string()
    })?;

    let recorder_repo = find_recorder_repo_dir(&recorder);

    fs::create_dir_all(trace_dir).map_err(|e| format!("failed to create trace dir: {}", e))?;

    // Step 1: Compile the Sway project with forc (needs the fuel-recorder's dev shell)
    let forc_output = if let Some(ref repo_dir) = recorder_repo {
        Command::new("direnv")
            .args(["exec", repo_dir.to_str().unwrap(), "forc", "build"])
            .current_dir(source_path)
            .output()
            .map_err(|e| format!("failed to run forc build via direnv: {}", e))?
    } else {
        Command::new("forc")
            .arg("build")
            .current_dir(source_path)
            .output()
            .map_err(|e| format!("failed to run forc build: {}", e))?
    };

    if !forc_output.status.success() {
        return Err(format!(
            "forc build failed:\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&forc_output.stdout),
            String::from_utf8_lossy(&forc_output.stderr)
        ));
    }

    // Step 2: Find the compiled bytecode
    let project_name = source_path.file_name().and_then(|n| n.to_str()).unwrap_or("flow_test");
    let bytecode = source_path.join(format!("out/debug/{}.bin", project_name));
    if !bytecode.exists() {
        return Err(format!(
            "forc build succeeded but compiled bytecode not found at {}",
            bytecode.display()
        ));
    }

    // Step 3: Record using --bytecode
    let output = run_recorder_command(
        &recorder,
        &[
            "record",
            "--bytecode",
            bytecode.to_str().unwrap(),
            "--out-dir",
            trace_dir.to_str().unwrap(),
        ],
    )?;

    if !output.status.success() {
        return Err(format!(
            "Fuel recorder failed:\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(())
}

/// Record a Move/Sui trace by invoking the `codetracer-move-recorder record` CLI.
///
/// Runs:
///   `<move-recorder> record <trace_file> --out-dir <trace_dir> --source <source_file>`
///
/// The Move recorder expects a pre-recorded trace file (e.g. `trace.json.zst`
/// produced by the Move compiler/VM test runner) and converts it into the
/// CodeTracer trace format. The `--source` flag provides the Move source file
/// for source mapping.
///
/// `source_path` must point to a trace file (`.json` or `.json.zst`), not a
/// directory. The source file for source mapping is discovered via
/// `find_move_flow_source()`.
///
/// Returns an error if the recorder binary is not found, or if recording fails.
fn record_move_trace(source_path: &Path, trace_dir: &Path) -> Result<(), String> {
    let recorder = find_move_recorder().ok_or_else(|| {
        "Move recorder not found. \
             Set CODETRACER_MOVE_RECORDER_PATH or build codetracer-move-recorder \
             (run `cargo build` inside the codetracer-move-recorder repo)."
            .to_string()
    })?;

    let move_source = find_move_flow_source().ok_or_else(|| {
        "Move flow test source file not found. \
             Ensure codetracer-move-recorder/test-programs/move/flow_test/sources/flow_test.move exists."
            .to_string()
    })?;

    fs::create_dir_all(trace_dir).map_err(|e| format!("failed to create trace dir: {}", e))?;

    let output = Command::new(&recorder)
        .args([
            "record",
            source_path.to_str().unwrap(),
            "--out-dir",
            trace_dir.to_str().unwrap(),
            "--source",
            move_source.to_str().unwrap(),
        ])
        .output()
        .map_err(|e| format!("failed to run Move recorder: {}", e))?;

    if !output.status.success() {
        return Err(format!(
            "Move recorder failed:\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(())
}

/// Record a Solana/SBF trace using the `--regs` pipeline.
///
/// Generates a synthetic register trace (.regs file) that simulates the
/// canonical flow test computation (a=10, b=32, sum=42, doubled=84, final=94)
/// and feeds it to the recorder along with the recorder's own binary as
/// an ELF (for DWARF source mapping demonstration).
///
/// This approach works without `cargo-build-sbf` or the full Solana SDK.
/// For full end-to-end testing with real SBF programs, use Mollusk or
/// LiteSVM as the execution harness (requires the Solana toolchain).
fn record_solana_trace(source_path: &Path, trace_dir: &Path) -> Result<(), String> {
    let recorder = find_solana_recorder().ok_or_else(|| {
        "Solana recorder not found. \
             Set CODETRACER_SOLANA_RECORDER_PATH or build codetracer-solana-recorder \
             (run `cargo build` inside the codetracer-solana-recorder repo)."
            .to_string()
    })?;

    fs::create_dir_all(trace_dir).map_err(|e| format!("failed to create trace dir: {}", e))?;

    // Generate a synthetic .regs file with the canonical arithmetic.
    // Each row = 12 × u64 (96 bytes): r0-r10 (registers) + r11 (PC).
    // We simulate 9 instructions that compute a=10, b=32, sum=42, doubled=84, final=94.
    let mut regs_data = Vec::new();
    let steps: Vec<[u64; 12]> = vec![
        // PC=0: mov r1, 10
        [0, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        // PC=1: mov r2, 32
        [0, 10, 32, 0, 0, 0, 0, 0, 0, 0, 0, 1],
        // PC=2: mov r3, r1 (sum = a)
        [0, 10, 32, 10, 0, 0, 0, 0, 0, 0, 0, 2],
        // PC=3: add r3, r2 (sum = a + b = 42)
        [0, 10, 32, 42, 0, 0, 0, 0, 0, 0, 0, 3],
        // PC=4: mov r4, r3 (doubled = sum)
        [0, 10, 32, 42, 42, 0, 0, 0, 0, 0, 0, 4],
        // PC=5: mul r4, 2 (doubled = sum * 2 = 84)
        [0, 10, 32, 42, 84, 0, 0, 0, 0, 0, 0, 5],
        // PC=6: mov r0, r4 (final = doubled)
        [84, 10, 32, 42, 84, 0, 0, 0, 0, 0, 0, 6],
        // PC=7: add r0, r1 (final = doubled + a = 94)
        [94, 10, 32, 42, 84, 0, 0, 0, 0, 0, 0, 7],
        // PC=8: exit
        [94, 10, 32, 42, 84, 0, 0, 0, 0, 0, 0, 8],
    ];
    for step in &steps {
        for &val in step {
            regs_data.extend_from_slice(&val.to_le_bytes());
        }
    }

    let regs_path = trace_dir.join("synthetic.regs");
    fs::write(&regs_path, &regs_data).map_err(|e| format!("failed to write synthetic .regs file: {}", e))?;

    // Use the recorder's own binary as the ELF (it has DWARF debug info).
    // Source mapping will map to the recorder's own source, which is fine
    // for verifying the pipeline works end-to-end.
    let elf_path = &recorder;

    let output = run_recorder_command(
        &recorder,
        &[
            "record",
            elf_path.to_str().unwrap(),
            "--regs",
            regs_path.to_str().unwrap(),
            "--out-dir",
            trace_dir.to_str().unwrap(),
        ],
    )?;

    if !output.status.success() {
        return Err(format!(
            "Solana recorder failed:\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(())
}

/// Record a PolkaVM trace by invoking the `codetracer-polkavm-recorder record` CLI.
///
/// Runs:
///   `<polkavm-recorder> record <blob.polkavm> --out-dir <trace_dir>`
///
/// The PolkaVM recorder expects a pre-compiled `.polkavm` blob. If `source_path`
/// points to a `.rs` file instead, this function first attempts to build the blob
/// by running `cargo run --example build_flow_test_blob` inside the recorder repo
/// (via `direnv exec` for the correct dev shell).
///
/// Returns an error if the recorder binary is not found, or if recording fails.
fn record_polkavm_trace(source_path: &Path, trace_dir: &Path) -> Result<(), String> {
    let recorder = find_polkavm_recorder().ok_or_else(|| {
        "PolkaVM recorder not found. \
             Set CODETRACER_POLKAVM_RECORDER_PATH or build codetracer-polkavm-recorder \
             (run `cargo build` inside the codetracer-polkavm-recorder repo)."
            .to_string()
    })?;

    // If the source_path is a .rs file, we need to build the .polkavm blob first.
    // The PolkaVM recorder only accepts pre-compiled blobs.
    let blob_path = if source_path.extension().and_then(|e| e.to_str()) == Some("rs") {
        let blob = source_path.with_extension("polkavm");
        if !blob.exists() {
            // Try to build the blob via the recorder repo's build_flow_test_blob example.
            let repo_dir = find_recorder_repo_dir(&recorder);
            if let Some(ref repo_dir) = repo_dir {
                eprintln!(
                    "Building PolkaVM blob via: direnv exec {} cargo run --example build_flow_test_blob",
                    repo_dir.display()
                );
                let build_output = Command::new("direnv")
                    .args([
                        "exec",
                        repo_dir.to_str().unwrap(),
                        "cargo",
                        "run",
                        "--example",
                        "build_flow_test_blob",
                    ])
                    .current_dir(repo_dir)
                    .output()
                    .map_err(|e| format!("failed to build PolkaVM blob: {}", e))?;

                if !build_output.status.success() {
                    return Err(format!(
                        "PolkaVM blob build failed:\nstdout: {}\nstderr: {}",
                        String::from_utf8_lossy(&build_output.stdout),
                        String::from_utf8_lossy(&build_output.stderr)
                    ));
                }
            }
        }

        if !blob.exists() {
            return Err(format!(
                "PolkaVM blob not found at {}. Build it with: \
                 cd codetracer-polkavm-recorder && cargo run --example build_flow_test_blob",
                blob.display()
            ));
        }
        blob
    } else {
        source_path.to_path_buf()
    };

    fs::create_dir_all(trace_dir).map_err(|e| format!("failed to create trace dir: {}", e))?;

    // Use run_recorder_command to wrap with `direnv exec` for the correct
    // dev shell environment.
    let output = run_recorder_command(
        &recorder,
        &[
            "record",
            blob_path.to_str().unwrap(),
            "--out-dir",
            trace_dir.to_str().unwrap(),
        ],
    )?;

    if !output.status.success() {
        return Err(format!(
            "PolkaVM recorder failed:\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(())
}

/// Record a Cairo trace by invoking the `codetracer-cairo-recorder record` CLI.
///
/// Runs:
///   `<cairo-recorder> record <source.cairo> --out-dir <trace_dir>`
///
/// The Cairo recorder compiles the Cairo source to Sierra bytecode, executes it
/// on the Cairo VM, captures step-by-step execution state, and writes
/// `trace.bin`, `trace_metadata.json`, and `trace_paths.json` into `trace_dir`.
///
/// Returns an error if the recorder binary is not found, or if recording fails.
fn record_cairo_trace(source_path: &Path, trace_dir: &Path) -> Result<(), String> {
    let recorder = find_cairo_recorder().ok_or_else(|| {
        "Cairo recorder not found. \
             Set CODETRACER_CAIRO_RECORDER_PATH or build codetracer-cairo-recorder \
             (run `cargo build` inside the codetracer-cairo-recorder repo)."
            .to_string()
    })?;

    fs::create_dir_all(trace_dir).map_err(|e| format!("failed to create trace dir: {}", e))?;

    let output = Command::new(&recorder)
        .args([
            "record",
            source_path.to_str().unwrap(),
            "--out-dir",
            trace_dir.to_str().unwrap(),
        ])
        .output()
        .map_err(|e| format!("failed to run Cairo recorder: {}", e))?;

    if !output.status.success() {
        return Err(format!(
            "Cairo recorder failed:\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(())
}

/// Record a Circom trace by invoking the `codetracer-circom-recorder record` CLI.
///
/// Runs:
///   `<circom-recorder> record <source.circom> --out-dir <trace_dir>`
///
/// The Circom recorder compiles the circuit, generates a witness via Wasm,
/// captures signal assignments step-by-step, and writes `trace.bin`,
/// `trace_metadata.json`, and `trace_paths.json` into `trace_dir`.
///
/// Returns an error if the recorder binary is not found, or if recording fails.
fn record_circom_trace(source_path: &Path, trace_dir: &Path) -> Result<(), String> {
    let recorder = find_circom_recorder().ok_or_else(|| {
        "Circom recorder not found. \
             Set CODETRACER_CIRCOM_RECORDER_PATH or build codetracer-circom-recorder \
             (run `cargo build` inside the codetracer-circom-recorder repo)."
            .to_string()
    })?;

    fs::create_dir_all(trace_dir).map_err(|e| format!("failed to create trace dir: {}", e))?;

    // The circom recorder needs the `circom` compiler on PATH, which is
    // provided by the recorder repo's nix dev shell. Use `run_recorder_command`
    // to automatically wrap with `direnv exec` when a `.envrc` is present.
    let output = run_recorder_command(
        &recorder,
        &[
            "record",
            source_path.to_str().unwrap(),
            "--out-dir",
            trace_dir.to_str().unwrap(),
        ],
    )?;

    if !output.status.success() {
        return Err(format!(
            "Circom recorder failed:\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(())
}

/// Record a Leo trace by invoking the `codetracer-leo-recorder record` CLI.
///
/// Runs:
///   `<leo-recorder> record <source.leo> --out-dir <trace_dir>`
///
/// The Leo recorder interprets the Leo program, captures step-by-step execution
/// state, and writes `trace.bin`, `trace_metadata.json`, and `trace_paths.json`
/// into `trace_dir`.
///
/// Returns an error if the recorder binary is not found, or if recording fails.
fn record_leo_trace(source_path: &Path, trace_dir: &Path) -> Result<(), String> {
    let recorder = find_leo_recorder().ok_or_else(|| {
        "Leo recorder not found. \
             Set CODETRACER_LEO_RECORDER_PATH or build codetracer-leo-recorder \
             (run `cargo build` inside the codetracer-leo-recorder repo)."
            .to_string()
    })?;

    fs::create_dir_all(trace_dir).map_err(|e| format!("failed to create trace dir: {}", e))?;

    let output = Command::new(&recorder)
        .args([
            "record",
            source_path.to_str().unwrap(),
            "--out-dir",
            trace_dir.to_str().unwrap(),
        ])
        .output()
        .map_err(|e| format!("failed to run Leo recorder: {}", e))?;

    if !output.status.success() {
        return Err(format!(
            "Leo recorder failed:\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(())
}

/// Record a Tolk/TON trace by invoking the `codetracer-ton-recorder record` CLI.
///
/// Runs:
///   `<ton-recorder> record <source.tolk> --out-dir <trace_dir>`
///
/// The TON recorder compiles the Tolk source, executes it on the TVM, captures
/// step-by-step execution state, and writes `trace.bin`, `trace_metadata.json`,
/// and `trace_paths.json` into `trace_dir`.
///
/// Returns an error if the recorder binary is not found, or if recording fails.
fn record_tolk_trace(source_path: &Path, trace_dir: &Path) -> Result<(), String> {
    let recorder = find_tolk_recorder().ok_or_else(|| {
        "Tolk/TON recorder not found. \
             Set CODETRACER_TOLK_RECORDER_PATH or build codetracer-ton-recorder \
             (run `cargo build` inside the codetracer-ton-recorder repo)."
            .to_string()
    })?;

    fs::create_dir_all(trace_dir).map_err(|e| format!("failed to create trace dir: {}", e))?;

    let output = Command::new(&recorder)
        .args([
            "record",
            source_path.to_str().unwrap(),
            "--out-dir",
            trace_dir.to_str().unwrap(),
        ])
        .output()
        .map_err(|e| format!("failed to run TON recorder: {}", e))?;

    if !output.status.success() {
        return Err(format!(
            "TON recorder failed:\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(())
}

/// Record an Aiken/Cardano trace by invoking the `codetracer-cardano-recorder record` CLI.
///
/// Runs:
///   `<cardano-recorder> record <source.ak> --out-dir <trace_dir>`
///
/// The Cardano recorder compiles the Aiken source to UPLC, executes it on the
/// CEK machine, captures step-by-step execution state, and writes `trace.bin`,
/// `trace_metadata.json`, and `trace_paths.json` into `trace_dir`.
///
/// Returns an error if the recorder binary is not found, or if recording fails.
fn record_aiken_trace(source_path: &Path, trace_dir: &Path) -> Result<(), String> {
    let recorder = find_aiken_recorder().ok_or_else(|| {
        "Aiken/Cardano recorder not found. \
             Set CODETRACER_AIKEN_RECORDER_PATH or build codetracer-cardano-recorder \
             (run `cargo build` inside the codetracer-cardano-recorder repo)."
            .to_string()
    })?;

    fs::create_dir_all(trace_dir).map_err(|e| format!("failed to create trace dir: {}", e))?;

    let output = Command::new(&recorder)
        .args([
            "record",
            source_path.to_str().unwrap(),
            "--out-dir",
            trace_dir.to_str().unwrap(),
        ])
        .output()
        .map_err(|e| format!("failed to run Cardano recorder: {}", e))?;

    if !output.status.success() {
        return Err(format!(
            "Cardano recorder failed:\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(())
}

/// Build the Go helper binary (`cadence-trace-helper`) from the sibling
/// `codetracer-flow-recorder/go-helper/` directory.
///
/// The helper is built inside the flow recorder's Nix dev shell (via
/// `direnv exec`) so that the Cadence Go SDK and Go toolchain are available.
/// The compiled binary is placed in the flow recorder's `target/debug/`
/// directory for reuse across test runs.
///
/// Returns the absolute path to the built binary, or an error if the build
/// fails.
fn build_cadence_go_helper(flow_recorder_dir: &Path) -> Result<PathBuf, String> {
    let go_helper_dir = flow_recorder_dir.join("go-helper");
    if !go_helper_dir.exists() {
        return Err(format!(
            "Go helper source directory not found at {}",
            go_helper_dir.display()
        ));
    }

    let output_dir = flow_recorder_dir.join("target/debug");
    fs::create_dir_all(&output_dir).map_err(|e| format!("failed to create output dir for Go helper: {}", e))?;

    let helper_bin = output_dir.join("cadence-trace-helper");

    // Build the Go helper using the flow recorder's dev shell for Go + Cadence SDK
    let build_output = Command::new("direnv")
        .args([
            "exec",
            flow_recorder_dir.to_str().unwrap(),
            "go",
            "build",
            "-o",
            helper_bin.to_str().unwrap(),
            ".",
        ])
        .current_dir(&go_helper_dir)
        .output()
        .map_err(|e| format!("failed to run `direnv exec ... go build` for Go helper: {}", e))?;

    if !build_output.status.success() {
        return Err(format!(
            "Go helper build failed:\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&build_output.stdout),
            String::from_utf8_lossy(&build_output.stderr)
        ));
    }

    Ok(safe_canonicalize(&helper_bin))
}

/// Record a Cadence/Flow trace by invoking the `codetracer-flow-recorder record` CLI.
///
/// Runs:
///   `<flow-recorder> record <source.cdc> --out-dir <trace_dir>`
///
/// The Flow recorder interprets the Cadence program, captures step-by-step
/// execution state, and writes `trace.bin`, `trace_metadata.json`, and
/// `trace_paths.json` into `trace_dir`.
///
/// Before running the recorder, this function builds the Go helper binary
/// (`cadence-trace-helper`) that the recorder shells out to for Cadence
/// interpretation. The helper path is passed via the `CADENCE_HELPER_BIN`
/// environment variable.
///
/// Returns an error if the recorder binary is not found, or if recording fails.
fn record_cadence_trace(source_path: &Path, trace_dir: &Path) -> Result<(), String> {
    let recorder = find_cadence_recorder().ok_or_else(|| {
        "Cadence/Flow recorder not found. \
             Set CODETRACER_CADENCE_RECORDER_PATH or build codetracer-flow-recorder \
             (run `cargo build` inside the codetracer-flow-recorder repo)."
            .to_string()
    })?;

    // Resolve the flow recorder repo directory from the binary location.
    // Binary is at <repo>/target/debug/codetracer-flow-recorder, so the repo
    // root is three levels up.
    let flow_recorder_dir = recorder
        .parent()
        .and_then(|p| p.parent())
        .and_then(|p| p.parent())
        .ok_or_else(|| {
            format!(
                "Cannot determine flow recorder repo directory from binary path: {}",
                recorder.display()
            )
        })?;

    // Build the Go helper binary (cadence-trace-helper) if not already present
    // or if the source is newer. We always rebuild to stay safe.
    let helper_bin = if env::var("CADENCE_HELPER_BIN").is_ok() {
        // User has explicitly set the helper path -- respect it.
        None
    } else {
        Some(build_cadence_go_helper(flow_recorder_dir)?)
    };

    fs::create_dir_all(trace_dir).map_err(|e| format!("failed to create trace dir: {}", e))?;

    let mut cmd = Command::new(&recorder);
    cmd.args([
        "record",
        source_path.to_str().unwrap(),
        "--out-dir",
        trace_dir.to_str().unwrap(),
    ]);

    // Point the recorder at the freshly built Go helper.
    if let Some(ref bin) = helper_bin {
        cmd.env("CADENCE_HELPER_BIN", bin);
    }

    let output = cmd
        .output()
        .map_err(|e| format!("failed to run Flow recorder: {}", e))?;

    if !output.status.success() {
        return Err(format!(
            "Flow recorder failed:\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(())
}

/// Resolve the `codetracer-beam-recorder` binary plus its repo and prepare a
/// PATH that lets `mix` and `erl` find it (the recorder lives under
/// `target/{debug,release}/`).
///
/// Returns `(repo_dir, recorder_binary, prepared_path_var)`.
fn resolve_beam_recorder_environment() -> Result<(PathBuf, PathBuf, std::ffi::OsString), String> {
    let recorder_repo = find_beam_recorder_repo().ok_or_else(|| {
        "BEAM recorder repo not found. Set CODETRACER_BEAM_RECORDER_PATH \
         to the codetracer-beam-recorder checkout (legacy: \
         CODETRACER_ELIXIR_RECORDER_PATH)."
            .to_string()
    })?;
    let recorder = find_beam_recorder().ok_or_else(|| {
        "codetracer-beam-recorder binary not found. Build the recorder repo \
         or set CODETRACER_BEAM_RECORDER_BIN (legacy: \
         CODETRACER_ELIXIR_RECORDER_BIN)."
            .to_string()
    })?;
    let recorder_bin_dir = recorder
        .parent()
        .ok_or_else(|| format!("recorder binary has no parent directory: {}", recorder.display()))?
        .to_path_buf();
    let mut path_entries = vec![recorder_bin_dir];
    if let Some(existing_path) = env::var_os("PATH") {
        path_entries.extend(env::split_paths(&existing_path));
    }
    let path_with_recorder =
        env::join_paths(path_entries).map_err(|e| format!("failed to build recorder PATH: {}", e))?;
    Ok((recorder_repo, recorder, path_with_recorder))
}

/// Records the canonical Elixir Mix fixture by:
///   1. Resolving the BEAM recorder binary and repo.
///   2. Pre-compiling the recorder's Mix tasks (compile.codetracer +
///      codetracer.record) into a private `task_ebin` so they're loadable from
///      inside the fixture's `mix` invocation regardless of where the recorder
///      repo is mounted.
///   3. Running `mix codetracer.record --build-dir ... --out-dir <trace_dir>
///      --include-module Elixir.CanonicalFlow --eval CanonicalFlow.main()`.
///
/// The output `<trace_dir>` ends up populated with `trace_meta.json`,
/// `*.ct` CTFS bundle, manifests, source-map artifacts, and the legacy
/// source_map/files copies — all of which the db-backend's CTFS reader can
/// consume.
fn record_elixir_trace(source_path: &Path, trace_dir: &Path) -> Result<(), String> {
    let (recorder_repo, recorder, path_with_recorder) = resolve_beam_recorder_environment()?;

    if !source_path.join("mix.exs").exists() {
        return Err(format!("Elixir Mix project not found at {}", source_path.display()));
    }

    fs::create_dir_all(trace_dir).map_err(|e| format!("failed to create trace dir: {}", e))?;
    let temp_root = trace_dir
        .parent()
        .ok_or_else(|| format!("trace dir has no parent: {}", trace_dir.display()))?;
    let build_dir = temp_root.join("codetracer-beam-build");
    let mix_build_root = temp_root.join("mix-build");
    let task_ebin = temp_root.join("codetracer-beam-task-ebin");
    fs::create_dir_all(&task_ebin).map_err(|e| format!("failed to create Mix task ebin dir: {}", e))?;

    let recorder_bin_dir_arg = recorder.parent().map(|p| p.display().to_string()).unwrap_or_default();

    let run_in_recorder_shell = |program: &str, args: &[&str], cwd: &Path| -> Result<std::process::Output, String> {
        let mut command = if recorder_repo.join(".envrc").exists() && is_command_available("direnv") {
            let mut cmd = Command::new("direnv");
            cmd.arg("exec")
                .arg(&recorder_repo)
                .arg("bash")
                .arg("-lc")
                .arg("export PATH=\"$1:$PATH\"; shift; exec \"$@\"")
                .arg("codetracer-beam-recorder-path")
                .arg(&recorder_bin_dir_arg)
                .arg(program);
            cmd
        } else {
            Command::new(program)
        };

        command
            .args(args)
            .current_dir(cwd)
            .env("MIX_ENV", "test")
            .env("MIX_BUILD_ROOT", &mix_build_root)
            .env("TMPDIR", temp_root)
            .env("CODETRACER_BEAM_RECORDER_ROOT", &recorder_repo)
            .env("CODETRACER_BEAM_RECORDER_BIN", &recorder)
            // Keep the legacy alias populated for one release while downstream
            // tooling migrates to the BEAM-prefixed names.
            .env("CODETRACER_ELIXIR_RECORDER_ROOT", &recorder_repo)
            .env("CODETRACER_ELIXIR_RECORDER_BIN", &recorder)
            .env("PATH", &path_with_recorder)
            .output()
            .map_err(|e| format!("failed to run {} in recorder dev shell: {}", program, e))
    };

    // Pre-compile the recorder-owned Mix tasks. The task source layout in
    // codetracer-beam-recorder is:
    //   - lib/codetracer_beam_recorder/elixir_source_map.ex (compiler tracer)
    //   - lib/mix/tasks/compile.codetracer.ex
    //   - lib/mix/tasks/codetracer.record.ex
    let task_sources = [
        recorder_repo.join("lib/codetracer_beam_recorder/elixir_source_map.ex"),
        recorder_repo.join("lib/mix/tasks/compile.codetracer.ex"),
        recorder_repo.join("lib/mix/tasks/codetracer.record.ex"),
    ];
    for source in &task_sources {
        if !source.is_file() {
            return Err(format!(
                "BEAM recorder task source not found at {}; layout out-of-sync with recorder",
                source.display()
            ));
        }
    }
    let mut elixirc_args = vec!["-o", task_ebin.to_str().unwrap()];
    for source in &task_sources {
        elixirc_args.push(source.to_str().unwrap());
    }
    let compile_tasks = run_in_recorder_shell("elixirc", &elixirc_args, &recorder_repo)?;
    if !compile_tasks.status.success() {
        return Err(format!(
            "BEAM recorder Mix task compilation failed with status {:?}:\nstdout: {}\nstderr: {}",
            compile_tasks.status.code(),
            String::from_utf8_lossy(&compile_tasks.stdout),
            String::from_utf8_lossy(&compile_tasks.stderr)
        ));
    }

    let task_ebin_arg = task_ebin.to_str().unwrap();
    let mix_args = [
        "codetracer.record",
        "--build-dir",
        build_dir.to_str().unwrap(),
        "--out-dir",
        trace_dir.to_str().unwrap(),
        "--include-module",
        "Elixir.CanonicalFlow",
        "--eval",
        "CanonicalFlow.main()",
    ];

    let output = {
        let mut command = if recorder_repo.join(".envrc").exists() && is_command_available("direnv") {
            let mut cmd = Command::new("direnv");
            cmd.arg("exec")
                .arg(&recorder_repo)
                .arg("bash")
                .arg("-lc")
                .arg("export PATH=\"$1:$PATH\"; shift; exec \"$@\"")
                .arg("codetracer-beam-recorder-path")
                .arg(&recorder_bin_dir_arg)
                .arg("mix");
            cmd
        } else {
            Command::new("mix")
        };

        command
            .args(mix_args)
            .current_dir(source_path)
            .env("ERL_LIBS", task_ebin_arg)
            .env("MIX_ENV", "test")
            .env("MIX_BUILD_ROOT", &mix_build_root)
            .env("TMPDIR", temp_root)
            .env("CODETRACER_BEAM_RECORDER_ROOT", &recorder_repo)
            .env("CODETRACER_BEAM_RECORDER_BIN", &recorder)
            .env("CODETRACER_ELIXIR_RECORDER_ROOT", &recorder_repo)
            .env("CODETRACER_ELIXIR_RECORDER_BIN", &recorder)
            .env("PATH", &path_with_recorder)
            .env("ELIXIR_ERL_OPTIONS", format!("-pa {}", task_ebin_arg))
            .output()
            .map_err(|e| format!("failed to run mix codetracer.record in recorder dev shell: {}", e))?
    };

    if !output.status.success() {
        return Err(format!(
            "BEAM recorder (Elixir) failed with status {:?}:\nstdout: {}\nstderr: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(())
}

/// Records the canonical Erlang fixture by:
///   1. Resolving the BEAM recorder binary and repo.
///   2. Compiling `src/canonical_flow.erl` with `erlc +debug_info` into a
///      temporary `ebin/` directory.
///   3. Running `<recorder> record --out-dir <trace_dir> -- erl -noshell -pa
///      <ebin> -s canonical_flow main -s init stop`. This matches the launch
///      pattern used by the recorder's own integration tests
///      (`tests/integration/runtime_session_test.exs`) so we exercise the
///      same code path.
fn record_erlang_trace(source_path: &Path, trace_dir: &Path) -> Result<(), String> {
    let (recorder_repo, recorder, path_with_recorder) = resolve_beam_recorder_environment()?;

    let erl_source = source_path.join("src/canonical_flow.erl");
    if !erl_source.is_file() {
        return Err(format!(
            "Erlang fixture not found at {} (expected canonical_flow.erl)",
            erl_source.display()
        ));
    }

    fs::create_dir_all(trace_dir).map_err(|e| format!("failed to create trace dir: {}", e))?;
    let temp_root = trace_dir
        .parent()
        .ok_or_else(|| format!("trace dir has no parent: {}", trace_dir.display()))?;
    let ebin_dir = temp_root.join("codetracer-beam-erlang-ebin");
    fs::create_dir_all(&ebin_dir).map_err(|e| format!("failed to create ebin dir: {}", e))?;

    // Run the given program inside the recorder repo's dev shell when one is
    // available — matches the Elixir helper for parity (BEAM tools may live in
    // the recorder's nix shell rather than the codetracer dev shell).
    let run_in_recorder_shell = |program: &str, args: &[&str], cwd: &Path| -> Result<std::process::Output, String> {
        let recorder_bin_dir_arg = recorder.parent().map(|p| p.display().to_string()).unwrap_or_default();
        let mut command = if recorder_repo.join(".envrc").exists() && is_command_available("direnv") {
            let mut cmd = Command::new("direnv");
            cmd.arg("exec")
                .arg(&recorder_repo)
                .arg("bash")
                .arg("-lc")
                .arg("export PATH=\"$1:$PATH\"; shift; exec \"$@\"")
                .arg("codetracer-beam-recorder-path")
                .arg(&recorder_bin_dir_arg)
                .arg(program);
            cmd
        } else {
            Command::new(program)
        };

        command
            .args(args)
            .current_dir(cwd)
            .env("TMPDIR", temp_root)
            .env("CODETRACER_BEAM_RECORDER_ROOT", &recorder_repo)
            .env("CODETRACER_BEAM_RECORDER_BIN", &recorder)
            .env("CODETRACER_ELIXIR_RECORDER_ROOT", &recorder_repo)
            .env("CODETRACER_ELIXIR_RECORDER_BIN", &recorder)
            .env("PATH", &path_with_recorder)
            .output()
            .map_err(|e| format!("failed to run {} in recorder dev shell: {}", program, e))
    };

    // Step 1: compile the Erlang source with debug_info so the recorder's
    // erl_anno-based source-location resolver can recover line numbers.
    let erlc_output = run_in_recorder_shell(
        "erlc",
        &[
            "+debug_info",
            "-o",
            ebin_dir.to_str().unwrap(),
            erl_source.to_str().unwrap(),
        ],
        source_path,
    )?;
    if !erlc_output.status.success() {
        return Err(format!(
            "erlc {} failed with status {:?}:\nstdout: {}\nstderr: {}",
            erl_source.display(),
            erlc_output.status.code(),
            String::from_utf8_lossy(&erlc_output.stdout),
            String::from_utf8_lossy(&erlc_output.stderr)
        ));
    }

    // Step 2: drive the recorder around `erl -noshell -pa <ebin> -s
    // canonical_flow main -s init stop`.
    let recorder_args = [
        "record",
        "--out-dir",
        trace_dir.to_str().unwrap(),
        "--",
        "erl",
        "-noshell",
        "-pa",
        ebin_dir.to_str().unwrap(),
        "-s",
        "canonical_flow",
        "main",
        "-s",
        "init",
        "stop",
    ];

    let output = {
        let mut command = if recorder_repo.join(".envrc").exists() && is_command_available("direnv") {
            let recorder_bin_dir_arg = recorder.parent().map(|p| p.display().to_string()).unwrap_or_default();
            let mut cmd = Command::new("direnv");
            cmd.arg("exec")
                .arg(&recorder_repo)
                .arg("bash")
                .arg("-lc")
                .arg("export PATH=\"$1:$PATH\"; shift; exec \"$@\"")
                .arg("codetracer-beam-recorder-path")
                .arg(&recorder_bin_dir_arg)
                .arg(recorder.to_str().unwrap());
            cmd
        } else {
            Command::new(&recorder)
        };

        command
            .args(recorder_args)
            .current_dir(source_path)
            .env("TMPDIR", temp_root)
            .env("CODETRACER_BEAM_RECORDER_ROOT", &recorder_repo)
            .env("CODETRACER_BEAM_RECORDER_BIN", &recorder)
            .env("PATH", &path_with_recorder)
            .output()
            .map_err(|e| format!("failed to run codetracer-beam-recorder for Erlang: {}", e))?
    };

    if !output.status.success() {
        return Err(format!(
            "BEAM recorder (Erlang) failed with status {:?}:\nstdout: {}\nstderr: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(())
}

impl TestRecording {
    /// Create a new DB-based test recording (Python/Ruby/Noir) without rr or ct-native-replay.
    ///
    /// For interpreted languages, the "binary_path" is the source path itself.
    pub fn create_db_trace(source_path: &Path, language: Language, version_label: &str) -> Result<Self, String> {
        Self::create_db_trace_with_format(source_path, language, version_label, "binary")
    }

    /// Create a DB-based trace recording with a specific trace format.
    ///
    /// The `trace_format` parameter is passed to the recorder via the
    /// `CODETRACER_TRACE_FORMAT` environment variable. Supported values
    /// depend on the recorder but typically include `"binary"` (default,
    /// CBOR+Zstd) and `"ctfs"` (the `.ct` CTFS container format).
    ///
    /// For interpreted languages, the "binary_path" is the source path itself.
    pub fn create_db_trace_with_format(
        source_path: &Path,
        language: Language,
        version_label: &str,
        trace_format: &str,
    ) -> Result<Self, String> {
        let temp_dir = std::env::temp_dir().join(format!(
            "flow_test_{}_{}_{}_{}",
            language.extension(),
            trace_format,
            version_label.replace('.', "_"),
            std::process::id()
        ));

        // Clean up any existing temp directory. In sandboxed builds (nix),
        // remove_dir_all can fail with ENOTEMPTY if another test process
        // has handles open. Retry once after a short delay, then proceed.
        if temp_dir.exists() && fs::remove_dir_all(&temp_dir).is_err() {
            std::thread::sleep(std::time::Duration::from_millis(100));
            let _ = fs::remove_dir_all(&temp_dir);
        }
        fs::create_dir_all(&temp_dir).map_err(|e| format!("failed to create temp dir: {}", e))?;

        let trace_dir = temp_dir.join("trace");

        // Record trace using the appropriate language recorder
        match language {
            Language::Python => record_python_trace_with_format(source_path, &trace_dir, trace_format)?,
            Language::Ruby => record_ruby_trace_with_format(source_path, &trace_dir, trace_format)?,
            Language::JavaScript => record_javascript_trace(source_path, &trace_dir)?,
            Language::Bash => record_bash_trace(source_path, &trace_dir)?,
            Language::Zsh => record_zsh_trace(source_path, &trace_dir)?,
            Language::Noir => record_noir_trace(source_path, &trace_dir)?,
            Language::RustWasm => {
                // source_path is the Cargo project directory; build then record
                let wasm_binary = build_wasm_test_program(source_path)?;
                record_wasm_trace(&wasm_binary, &trace_dir)?;
            }
            Language::Solidity => record_solidity_trace(source_path, &trace_dir)?,
            Language::Masm => record_masm_trace(source_path, &trace_dir)?,
            Language::Sway => record_fuel_trace(source_path, &trace_dir)?,
            Language::Move => record_move_trace(source_path, &trace_dir)?,
            Language::Solana => record_solana_trace(source_path, &trace_dir)?,
            Language::PolkaVM => record_polkavm_trace(source_path, &trace_dir)?,
            Language::Cairo => record_cairo_trace(source_path, &trace_dir)?,
            Language::Circom => record_circom_trace(source_path, &trace_dir)?,
            Language::Leo => record_leo_trace(source_path, &trace_dir)?,
            Language::Tolk => record_tolk_trace(source_path, &trace_dir)?,
            Language::Aiken => record_aiken_trace(source_path, &trace_dir)?,
            Language::Cadence => record_cadence_trace(source_path, &trace_dir)?,
            Language::Elixir => {
                // The BEAM recorder always writes the CTFS bundle layout; the
                // legacy `--format` flag is gone. We log when callers ask for
                // anything other than ctfs so silent regressions get surfaced.
                if trace_format != "ctfs" {
                    eprintln!(
                        "NOTE: BEAM recorder always emits CTFS; ignoring trace_format={} for Elixir",
                        trace_format
                    );
                }
                record_elixir_trace(source_path, &trace_dir)?
            }
            Language::Erlang => {
                if trace_format != "ctfs" {
                    eprintln!(
                        "NOTE: BEAM recorder always emits CTFS; ignoring trace_format={} for Erlang",
                        trace_format
                    );
                }
                record_erlang_trace(source_path, &trace_dir)?
            }
            _ => return Err(format!("{:?} is not a DB-based language", language)),
        }

        // Verify the essential trace files were produced.
        // Different formats produce different files:
        //   - JSON format: trace.json
        //   - Binary (CBOR+Zstd): trace.bin
        //   - CTFS: trace.ct or <program_name>.ct (the shell recorder names
        //     the .ct file after the recorded script, not as "trace.ct")
        let trace_json = trace_dir.join("trace.json");
        let trace_bin = trace_dir.join("trace.bin");
        let trace_ct = trace_dir.join("trace.ct");
        let has_any_ct = trace_ct.exists()
            || fs::read_dir(&trace_dir)
                .map(|entries| {
                    entries
                        .filter_map(|e| e.ok())
                        .any(|e| e.path().extension().is_some_and(|ext| ext == "ct"))
                })
                .unwrap_or(false);
        let trace_metadata = trace_dir.join("trace_metadata.json");
        if !trace_json.exists() && !trace_bin.exists() && !has_any_ct {
            return Err(format!(
                "no trace file (trace.json, trace.bin, or *.ct) produced in {}",
                trace_dir.display()
            ));
        }
        if !trace_metadata.exists() {
            return Err(format!(
                "trace_metadata.json not produced at {}",
                trace_metadata.display()
            ));
        }

        Ok(TestRecording {
            trace_dir,
            source_path: source_path.to_path_buf(),
            binary_path: source_path.to_path_buf(), // interpreted langs have no binary
            temp_dir,
            language,
            version_label: version_label.to_string(),
        })
    }
}

/// Run a flow integration test for a DB-based language (Python, Ruby, JS, Noir, WASM, Bash, Zsh).
///
/// Similar to `run_flow_test()` but does not require ct-native-replay or rr.
/// Uses `create_db_trace()` for recording and `DapStdioTestClient` for
/// DAP communication (cross-platform, no Unix sockets needed).
///
/// For Python traces, the source file is copied into the trace_dir and paths
/// in the trace are relative to workdir (= trace_dir). We use the trace_dir
/// copy path for breakpoints so the path matches what the DB lookup expects.
/// For Ruby traces, paths are relative to the recorder's CWD, which is the
/// codetracer repo root, so the original source path matches via suffix match.
pub fn run_db_flow_test(config: &FlowTestConfig, version_label: &str) -> Result<(), String> {
    run_db_flow_test_with_format(config, version_label, "binary")
}

/// Run a flow integration test for a DB-based language with a specific trace format.
///
/// Same as `run_db_flow_test` but records the trace in the given format.
/// The `trace_format` parameter is passed through to
/// `TestRecording::create_db_trace_with_format` (and ultimately to the recorder
/// via the `CODETRACER_TRACE_FORMAT` environment variable).
///
/// Supported formats: `"binary"` (default CBOR+Zstd), `"ctfs"` (`.ct` container).
pub fn run_db_flow_test_with_format(
    config: &FlowTestConfig,
    version_label: &str,
    trace_format: &str,
) -> Result<(), String> {
    println!("Source: {}", config.source_path.display());
    println!("Language: {:?}", config.language);
    println!("Version: {}", version_label);
    println!("Trace format: {}", trace_format);

    // Create DB-based recording (no rr needed)
    println!("Recording trace...");
    let recording =
        TestRecording::create_db_trace_with_format(&config.source_path, config.language, version_label, trace_format)?;
    println!("Recording created at: {}", recording.trace_dir.display());

    // Start DAP client via stdio (cross-platform, no Unix sockets)
    println!("Starting DAP stdio client...");
    let mut client = DapStdioTestClient::start()?;

    // Initialize and launch
    println!("Initializing DAP session...");
    client.initialize_and_launch(&recording)?;

    // Determine the breakpoint path. For DB traces, the trace stores relative
    // paths and the DAP server resolves them against the trace's workdir.
    // We use the trace-dir copy of the source file so path lookup succeeds.
    let breakpoint_source = if config.language == Language::Python || config.language == Language::Solidity {
        // Python and Solidity recorders copy the source into trace_dir and set
        // workdir = trace_dir, storing just the filename in trace_paths.json.
        // Use the trace_dir copy so path lookup succeeds.
        let filename = config.source_path.file_name().unwrap();
        recording.trace_dir.join(filename)
    } else if config.language == Language::Noir {
        // For Noir, source_path is the Nargo project directory (needed by
        // nargo trace). The actual source file is src/main.nr within it.
        // nargo trace stores absolute paths, so the suffix-match works.
        config.source_path.join("src/main.nr")
    } else if config.language == Language::RustWasm {
        // For WASM, source_path is the Cargo project directory.
        // wazero stores absolute source paths in trace_paths.json,
        // so the suffix-match works with the actual .rs source file.
        config.source_path.join("src/main.rs")
    } else if config.language == Language::Stylus {
        // For Stylus, source_path is the Cargo project directory.
        // wazero stores absolute source paths in trace_paths.json.
        // The contract code is in src/lib.rs (not main.rs).
        config.source_path.join("src/lib.rs")
    } else if config.language == Language::Bash || config.language == Language::Zsh {
        // Bash/Zsh recorder stores absolute paths, suffix-match works
        config.source_path.clone()
    } else {
        // Ruby and JavaScript store paths that are handled by suffix-match.
        config.source_path.clone()
    };

    // Set breakpoint
    println!(
        "Setting breakpoint at {}:{}...",
        breakpoint_source.display(),
        config.breakpoint_line
    );
    client.set_breakpoint(&breakpoint_source, config.breakpoint_line)?;

    // Continue to breakpoint
    println!("Continuing to breakpoint...");
    let location = client.continue_to_breakpoint()?;
    println!("Stopped at: {}:{}", location.path, location.line);

    // Request flow data
    println!("Requesting flow data...");
    let flow = client.request_flow(location)?;
    println!("Flow has {} steps", flow.steps.len());

    // Verify results — shared logic with run_flow_test()
    verify_flow_results(config, &flow)
}

/// Run a flow integration test with the given configuration (RR/TTD-based languages).
///
/// On Unix, uses `DapTestClient` (Unix sockets). On Windows (and as a fallback),
/// uses `DapStdioTestClient` (cross-platform stdio pipes).
///
/// Returns an error if ct-native-replay is not found or the replay backend (rr/TTD) is
/// not available, which allows tests to skip gracefully.
pub fn run_flow_test(config: &FlowTestConfig, version_label: &str) -> Result<(), String> {
    // Find ct-native-replay (formerly ct-rr-support)
    let ct_rr_support =
        find_ct_rr_support().ok_or("ct-native-replay not found in PATH or development locations".to_string())?;

    if !is_replay_backend_available() {
        return Err("replay backend not available (rr on Unix, TTD on Windows)".to_string());
    }

    println!("Using ct-native-replay: {}", ct_rr_support.display());
    println!("Source: {}", config.source_path.display());
    println!("Version: {}", version_label);

    // Create recording
    println!("Building and recording...");
    let recording = TestRecording::create(&config.source_path, config.language, version_label, &ct_rr_support)?;
    println!("Recording created at: {}", recording.trace_dir.display());

    // On Unix, try Unix socket client first; on Windows use stdio client
    #[cfg(unix)]
    {
        // Start DAP client via Unix sockets
        println!("Starting DAP client (Unix sockets)...");
        let mut client = DapTestClient::start(&recording.temp_dir, &ct_rr_support)?;

        // Initialize and launch
        println!("Initializing DAP session...");
        client.initialize_and_launch(&recording, &ct_rr_support)?;

        // Set breakpoint
        println!("Setting breakpoint at line {}...", config.breakpoint_line);
        client.set_breakpoint(&config.source_path, config.breakpoint_line)?;

        // Continue to breakpoint
        println!("Continuing to breakpoint...");
        let location = client.continue_to_breakpoint()?;
        println!("Stopped at: {}:{}", location.path, location.line);

        // Request flow data
        println!("Requesting flow data...");
        let flow = client.request_flow(location)?;
        println!("Flow has {} steps", flow.steps.len());

        // Verify results
        verify_flow_results(config, &flow)
    }

    #[cfg(not(unix))]
    {
        // Start DAP client via stdio (cross-platform)
        println!("Starting DAP stdio client...");
        let mut client = DapStdioTestClient::start()?;

        // Initialize and launch (using the rr-trace variant that passes recreator_exe)
        println!("Initializing DAP session...");
        client.initialize_and_launch_rr(&recording, &ct_rr_support)?;

        // Set breakpoint
        println!("Setting breakpoint at line {}...", config.breakpoint_line);
        client.set_breakpoint(&config.source_path, config.breakpoint_line)?;

        // Continue to breakpoint
        println!("Continuing to breakpoint...");
        let location = client.continue_to_breakpoint()?;
        println!("Stopped at: {}:{}", location.path, location.line);

        // Request flow data
        println!("Requesting flow data...");
        let flow = client.request_flow(location)?;
        println!("Flow has {} steps", flow.steps.len());

        // Verify results
        verify_flow_results(config, &flow)
    }
}

/// Verify flow results: check excluded identifiers, expected variables, and values.
///
/// Shared between `run_flow_test()` (RR-based) and `run_db_flow_test()` (DB-based).
fn verify_flow_results(config: &FlowTestConfig, flow: &FlowData) -> Result<(), String> {
    println!("\nVerifying flow data...");

    // Check excluded identifiers are NOT in the list
    for excluded in &config.excluded_identifiers {
        if flow.all_variables.contains(excluded) {
            return Err(format!(
                "'{}' should not be extracted as a variable (it's a function call)",
                excluded
            ));
        }
    }
    println!("Function call filtering PASSED");

    // Check expected variables ARE in the list
    let found_expected: Vec<&String> = config
        .expected_variables
        .iter()
        .filter(|v| flow.all_variables.contains(v))
        .collect();
    println!("Expected variables found: {:?}", found_expected);

    if found_expected.is_empty() {
        return Err(format!(
            "should find at least some of the expected variables: {:?}",
            config.expected_variables
        ));
    }
    println!("Variable extraction PASSED");

    // Check value loading
    let (loaded, not_loaded) = flow.count_loaded();
    println!("\nValue loading summary:");
    println!("  Loaded: {}", loaded);
    println!("  Not loaded: {}", not_loaded);

    // Verify specific expected values
    for (var_name, expected_value) in &config.expected_values {
        if let Some(value) = flow.values.get(var_name) {
            if FlowData::is_value_loaded(value) {
                if let Some(actual) = FlowData::extract_int_value(value) {
                    if actual != *expected_value {
                        return Err(format!("{} should be {}, got {}", var_name, expected_value, actual));
                    }
                    println!("  {} = {} (correct)", var_name, actual);
                }
            } else {
                println!("  {} = <NONE>", var_name);
            }
        }
    }

    if loaded == 0 {
        return Err("No values were loaded - local variables should be loadable".to_string());
    }
    println!("Value loading PASSED for {} variables", loaded);

    println!("\nTest completed successfully!");
    Ok(())
}
