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
use std::io::{self, BufReader, ErrorKind};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

/// Supported languages for test programs
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Language {
    Nim,
    Rust,
    C,
    Cpp,
    Go,
    Python,
    Ruby,
    Noir,
}

impl Language {
    pub fn extension(&self) -> &'static str {
        match self {
            Language::Nim => "nim",
            Language::Rust => "rs",
            Language::C => "c",
            Language::Cpp => "cpp",
            Language::Go => "go",
            Language::Python => "py",
            Language::Ruby => "rb",
            Language::Noir => "nr",
        }
    }

    /// Returns true for DB-based trace languages (Python, Ruby, Noir) that don't use rr.
    pub fn is_db_trace(&self) -> bool {
        matches!(self, Language::Python | Language::Ruby | Language::Noir)
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

        // Clean up any existing temp directory
        if temp_dir.exists() {
            fs::remove_dir_all(&temp_dir).map_err(|e| format!("failed to clean temp dir: {}", e))?;
        }
        fs::create_dir_all(&temp_dir).map_err(|e| format!("failed to create temp dir: {}", e))?;

        let trace_dir = temp_dir.join("trace");
        let binary_name = source_path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("test_program");
        let binary_path = temp_dir.join(binary_name);

        // Build the program
        let build_output = Command::new(ct_rr_support)
            .args(["build", source_path.to_str().unwrap(), binary_path.to_str().unwrap()])
            .output()
            .map_err(|e| format!("failed to run ct-rr-support build: {}", e))?;

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
            .map_err(|e| format!("failed to run ct-rr-support record: {}", e))?;

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
}

impl Drop for TestRecording {
    fn drop(&mut self) {
        // Clean up temp directory on drop
        fs::remove_dir_all(&self.temp_dir).ok();
    }
}

/// A DAP test client wrapper with helper methods
pub struct DapTestClient {
    client: DapClient,
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    db_backend: Child,
    _listener: UnixListener,
}

impl DapTestClient {
    /// Start a new DAP test client connected to db-backend
    pub fn start(temp_dir: &Path, ct_rr_support: &Path) -> Result<Self, String> {
        let db_backend_bin = env!("CARGO_BIN_EXE_db-backend");
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
            ct_rr_worker_exe: Some(ct_rr_support.to_path_buf()),
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

impl Drop for DapTestClient {
    fn drop(&mut self) {
        self.db_backend.kill().ok();
        self.db_backend.wait().ok();
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

/// Find ct-rr-support binary
pub fn find_ct_rr_support() -> Option<PathBuf> {
    // Highest priority: explicit CT_RR_SUPPORT_PATH environment variable.
    // Used by cross-repo test scripts to communicate the binary location.
    if let Ok(path) = env::var("CT_RR_SUPPORT_PATH") {
        let p = PathBuf::from(&path);
        if p.exists() && p.is_file() {
            return Some(p);
        }
        eprintln!(
            "WARNING: CT_RR_SUPPORT_PATH='{}' but file does not exist; falling back",
            path
        );
    }

    // First check PATH
    if let Ok(output) = Command::new("which").arg("ct-rr-support").output() {
        if output.status.success() {
            let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !path.is_empty() {
                return Some(PathBuf::from(path));
            }
        }
    }

    // Check common development locations
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let dev_locations = [
        "../../codetracer-rr-backend/target/debug/ct-rr-support",
        "../../codetracer-rr-backend/target/release/ct-rr-support",
        "../../../codetracer-rr-backend/target/debug/ct-rr-support",
    ];

    for loc in dev_locations {
        let path = manifest_dir.join(loc);
        if path.exists() {
            return Some(path.canonicalize().unwrap_or(path));
        }
    }

    // Check from home directory
    if let Some(home) = env::var_os("HOME") {
        let home_path = PathBuf::from(home);
        let home_locations = [
            "metacraft/codetracer-rr-backend/target/debug/ct-rr-support",
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

/// Check if rr is available
pub fn is_rr_available() -> bool {
    Command::new("rr").arg("--version").output().is_ok()
}

/// Accept a connection with timeout
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

/// Find the pure-Python recorder script (`trace.py`) via CARGO_MANIFEST_DIR.
///
/// The recorder is a git submodule at `libs/codetracer-python-recorder/` relative to
/// the top-level `codetracer/` directory. This function resolves the path from the
/// db-backend crate manifest directory: `../../libs/codetracer-python-recorder/
/// codetracer-pure-python-recorder/src/trace.py`.
///
/// Panics if the recorder is not found (it's a required submodule).
pub fn find_python_recorder() -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let recorder =
        manifest_dir.join("../../libs/codetracer-python-recorder/codetracer-pure-python-recorder/src/trace.py");
    assert!(
        recorder.exists(),
        "Python recorder not found at {}. Did you check out the codetracer-python-recorder submodule?",
        recorder.display()
    );
    recorder.canonicalize().unwrap_or(recorder)
}

/// Find the pure-Ruby recorder script via CARGO_MANIFEST_DIR.
///
/// The recorder is a git submodule at `libs/codetracer-ruby-recorder/` relative to
/// the top-level `codetracer/` directory. Same relative path as used by
/// `tracepoint_interpreter/tests.rs`.
///
/// Panics if the recorder is not found (it's a required submodule).
pub fn find_ruby_recorder() -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let recorder = manifest_dir.join(
        "../../libs/codetracer-ruby-recorder/gems/codetracer-pure-ruby-recorder/bin/codetracer-pure-ruby-recorder",
    );
    assert!(
        recorder.exists(),
        "Ruby recorder not found at {}. Did you check out the codetracer-ruby-recorder submodule?",
        recorder.display()
    );
    recorder.canonicalize().unwrap_or(recorder)
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
    let recorder = find_python_recorder();
    fs::create_dir_all(trace_dir).map_err(|e| format!("failed to create trace dir: {}", e))?;

    let output = Command::new("python")
        .args([recorder.to_str().unwrap(), source_path.to_str().unwrap()])
        .current_dir(trace_dir)
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
    let recorder = find_ruby_recorder();
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

/// Record a Noir trace by running `nargo trace` inside the Nargo project directory.
///
/// Unlike Python/Ruby where `source_path` is a single file, for Noir `source_path`
/// points to the project directory containing `Nargo.toml`. The `nargo trace` command
/// stores absolute source paths in `trace_paths.json`, so no source-file copying is
/// needed (unlike Python).
fn record_noir_trace(project_dir: &Path, trace_dir: &Path) -> Result<(), String> {
    fs::create_dir_all(trace_dir).map_err(|e| format!("failed to create trace dir: {}", e))?;

    let output = Command::new("nargo")
        .args(["trace", "--trace-dir", trace_dir.to_str().unwrap()])
        .current_dir(project_dir)
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

impl TestRecording {
    /// Create a new DB-based test recording (Python/Ruby/Noir) without rr or ct-rr-support.
    ///
    /// For interpreted languages, the "binary_path" is the source path itself.
    pub fn create_db_trace(source_path: &Path, language: Language, version_label: &str) -> Result<Self, String> {
        let temp_dir = std::env::temp_dir().join(format!(
            "flow_test_{}_{}_{}",
            language.extension(),
            version_label.replace('.', "_"),
            std::process::id()
        ));

        // Clean up any existing temp directory
        if temp_dir.exists() {
            fs::remove_dir_all(&temp_dir).map_err(|e| format!("failed to clean temp dir: {}", e))?;
        }
        fs::create_dir_all(&temp_dir).map_err(|e| format!("failed to create temp dir: {}", e))?;

        let trace_dir = temp_dir.join("trace");

        // Record trace using the appropriate language recorder
        match language {
            Language::Python => record_python_trace(source_path, &trace_dir)?,
            Language::Ruby => record_ruby_trace(source_path, &trace_dir)?,
            Language::Noir => record_noir_trace(source_path, &trace_dir)?,
            _ => return Err(format!("{:?} is not a DB-based language", language)),
        }

        // Verify the essential trace files were produced
        let trace_json = trace_dir.join("trace.json");
        let trace_metadata = trace_dir.join("trace_metadata.json");
        if !trace_json.exists() {
            return Err(format!("trace.json not produced at {}", trace_json.display()));
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

/// Run a flow integration test for a DB-based language (Python/Ruby).
///
/// Similar to `run_flow_test()` but does not require ct-rr-support or rr.
/// Uses `create_db_trace()` for recording and passes an empty path for
/// `ct_rr_worker_exe` (unused by DB traces).
///
/// For Python traces, the source file is copied into the trace_dir and paths
/// in the trace are relative to workdir (= trace_dir). We use the trace_dir
/// copy path for breakpoints so the path matches what the DB lookup expects.
/// For Ruby traces, paths are relative to the recorder's CWD, which is the
/// codetracer repo root, so the original source path matches via suffix match.
pub fn run_db_flow_test(config: &FlowTestConfig, version_label: &str) -> Result<(), String> {
    println!("Source: {}", config.source_path.display());
    println!("Language: {:?}", config.language);
    println!("Version: {}", version_label);

    // Create DB-based recording (no rr needed)
    println!("Recording trace...");
    let recording = TestRecording::create_db_trace(&config.source_path, config.language, version_label)?;
    println!("Recording created at: {}", recording.trace_dir.display());

    // Start DAP client — ct_rr_support path is unused for DB traces, pass empty path
    let dummy_ct_rr = PathBuf::from("");
    println!("Starting DAP client...");
    let mut client = DapTestClient::start(&recording.temp_dir, &dummy_ct_rr)?;

    // Initialize and launch — pass empty path for ct_rr_worker_exe
    println!("Initializing DAP session...");
    client.initialize_and_launch(&recording, &dummy_ct_rr)?;

    // Determine the breakpoint path. For DB traces, the trace stores relative
    // paths and the DAP server resolves them against the trace's workdir.
    // We use the trace-dir copy of the source file so path lookup succeeds.
    let breakpoint_source = if config.language == Language::Python {
        // Python recorder sets workdir = trace_dir, stores just the filename.
        // The source was copied into trace_dir by record_python_trace().
        let filename = config.source_path.file_name().unwrap();
        recording.trace_dir.join(filename)
    } else if config.language == Language::Noir {
        // For Noir, source_path is the Nargo project directory (needed by
        // nargo trace). The actual source file is src/main.nr within it.
        // nargo trace stores absolute paths, so the suffix-match works.
        config.source_path.join("src/main.nr")
    } else {
        // Ruby stores relative paths from CWD; handled by suffix-match.
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

/// Run a flow integration test with the given configuration (RR-based languages)
pub fn run_flow_test(config: &FlowTestConfig, version_label: &str) -> Result<(), String> {
    // Find ct-rr-support
    let ct_rr_support =
        find_ct_rr_support().ok_or("ct-rr-support not found in PATH or development locations".to_string())?;

    if !is_rr_available() {
        return Err("rr is not available".to_string());
    }

    println!("Using ct-rr-support: {}", ct_rr_support.display());
    println!("Source: {}", config.source_path.display());
    println!("Version: {}", version_label);

    // Create recording
    println!("Building and recording...");
    let recording = TestRecording::create(&config.source_path, config.language, version_label, &ct_rr_support)?;
    println!("Recording created at: {}", recording.trace_dir.display());

    // Start DAP client
    println!("Starting DAP client...");
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
