use std::error::Error;
use std::io::Write;
use std::io::{BufRead, BufReader};
#[cfg(unix)]
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

#[cfg(windows)]
use std::net::TcpStream;

use codetracer_trace_types::StepId;
use log::{debug, error, info, warn};
use serde::Deserialize;

use crate::db::DbRecordEvent;
use crate::expr_loader::ExprLoader;
use crate::lang::Lang;
#[cfg(windows)]
use crate::paths::CODETRACER_PATHS;
use crate::paths::log_path_for;
#[cfg(unix)]
use crate::paths::recreator_socket_path;
use crate::query::{
    ReplayQuery, TtdTracepointEvalMode, TtdTracepointEvalRequest, TtdTracepointEvalResponseEnvelope,
    TtdTracepointFunctionCallRequest, TtdTracepointValueClass,
};
use crate::replay::ReplaySession;
use crate::task::{
    Action, Breakpoint, CallLine, CtLoadLocalsArguments, Events, HistoryResultWithRecord, LoadHistoryArg, Location,
    LocationWithSourcemap, NO_STEP_ID, ProgramEvent, VariableWithRecord,
};
use crate::value::ValueRecordWithType;

fn replay_query_timeout() -> Duration {
    std::env::var("CODETRACER_REPLAY_QUERY_TIMEOUT_SECS")
        .ok()
        .and_then(|raw| raw.parse::<u64>().ok())
        .filter(|seconds| *seconds > 0)
        .map(Duration::from_secs)
        .unwrap_or_else(|| Duration::from_secs(10))
}
use codetracer_trace_types::{TypeKind, TypeRecord, TypeSpecificInfo};

#[cfg(unix)]
type WorkerStream = UnixStream;

#[cfg(windows)]
type WorkerStream = TcpStream;

#[cfg(not(any(unix, windows)))]
type WorkerStream = ();

#[derive(Debug)]
pub struct RecreatorReplaySession {
    pub stable: ReplayWorker,
    pub recreator_exe: PathBuf,
    pub rr_trace_folder: PathBuf,
    pub name: String,
    pub index: usize,
    /// The C-level location from the last `load_location` call, populated when
    /// the native backend applies Nim sourcemaps via `LoadLocationWithSourcemap`.
    last_c_location: Option<Location>,
}

#[derive(Debug)]
pub struct ReplayWorker {
    pub name: String,
    pub index: usize,
    pub active: bool,
    pub recreator_exe: PathBuf,
    pub rr_trace_folder: PathBuf,
    pub live_program: Option<PathBuf>,
    pub live_program_args: Vec<String>,
    pub live_cwd: Option<PathBuf>,
    pub live_recording_dir: Option<PathBuf>,
    /// M-REC-11: the run-id reserved for this worker (set by `start`,
    /// passed to the child via `$CODETRACER_RUN_ID`, and reused on the
    /// spawner side when computing the socket path).  Empty before
    /// `start` is called.
    run_id: String,
    /// M-REC-11: the trace's UUIDv7 — used by `start` to reserve a
    /// unique-within-this-process `run_id`.  May be empty for callers
    /// that have not yet been migrated; in that case the worker falls
    /// back to the legacy PID rendezvous.
    recording_id: String,
    process: Option<Child>,
    stream: Option<WorkerStream>,
}

#[derive(Default, Debug, Clone)]
pub struct RecreatorArgs {
    pub worker_exe: PathBuf,
    pub rr_trace_folder: PathBuf,
    pub name: String,
    pub live_program: Option<PathBuf>,
    pub live_program_args: Vec<String>,
    pub live_cwd: Option<PathBuf>,
    pub live_recording_dir: Option<PathBuf>,
    /// M-REC-11: the trace's UUIDv7.  Empty string keeps the legacy
    /// pid-derived run-id behaviour for callers that have not yet been
    /// migrated to plumb the recording id.  When non-empty, the
    /// spawner reserves a unique-within-this-process `run_id` derived
    /// from this id and passes it to the worker via
    /// `$CODETRACER_RUN_ID`.
    pub recording_id: String,
}

#[derive(Debug, Deserialize)]
struct WorkerTransportEndpoint {
    transport: String,
    address: String,
}

impl ReplayWorker {
    pub fn new(name: &str, index: usize, recreator_exe: &Path, rr_trace_folder: &Path) -> ReplayWorker {
        Self::new_with_recording_id(name, index, recreator_exe, rr_trace_folder, "")
    }

    /// M-REC-11 entry point: build a worker bound to a known
    /// `recording_id`.  Pass an empty string to preserve the legacy
    /// PID-derived rendezvous behaviour.
    pub fn new_with_recording_id(
        name: &str,
        index: usize,
        recreator_exe: &Path,
        rr_trace_folder: &Path,
        recording_id: &str,
    ) -> ReplayWorker {
        info!("new replay {name} {index} recording_id={recording_id}");
        ReplayWorker {
            name: name.to_string(),
            index,
            active: false,
            recreator_exe: PathBuf::from(recreator_exe),
            rr_trace_folder: PathBuf::from(rr_trace_folder),
            live_program: None,
            live_program_args: Vec::new(),
            live_cwd: None,
            live_recording_dir: None,
            run_id: String::new(),
            recording_id: recording_id.to_string(),
            process: None,
            stream: None,
        }
    }

    pub fn start(&mut self) -> Result<(), Box<dyn Error>> {
        if let Some(program) = &self.live_program {
            info!(
                "start: {} replay-worker --name {} --index {} --live-program {}",
                self.recreator_exe.display(),
                self.name,
                self.index,
                program.display()
            );
        } else {
            info!(
                "start: {} replay-worker --name {} --index {} {}",
                self.recreator_exe.display(),
                self.name,
                self.index,
                self.rr_trace_folder.display()
            );
        }

        // M-REC-11: reserve a process-unique run-id derived from the
        // trace's UUIDv7 (with a `-<seq>` suffix on collision).  Empty
        // recording_id keeps the legacy PID-derived behaviour for the
        // transitional period.  Stored on `self` so the spawner side
        // can compute the same socket path as the child in
        // `setup_worker_sockets` below.
        self.run_id = crate::paths::reserve_run_id_for_recording(&self.recording_id);

        // Redirect worker stderr to a log file for debugging.
        // Co-locate with the worker's UDS in the per-run directory so the
        // socket and its stderr log share lifecycle (XDG_RUNTIME_DIR on
        // Linux, fallback tmp_path elsewhere — see paths::run_dir_for).
        let log_path = log_path_for("ct-native-replay", &self.name, self.index, &self.run_id)?;
        info!("worker stderr log: {}", log_path.display());
        let stderr_file = std::fs::File::create(&log_path)?;

        let mut command = Command::new(&self.recreator_exe);
        command
            .arg("replay-worker")
            .arg("--name")
            .arg(&self.name)
            .arg("--index")
            .arg(self.index.to_string());
        if let Some(program) = &self.live_program {
            command.arg("--live-program").arg(program);
            if let Some(dir) = &self.live_recording_dir {
                command.arg("--live-recording-dir").arg(dir);
            }
            if let Some(cwd) = &self.live_cwd {
                command.arg("--live-cwd").arg(cwd);
            }
            for arg in &self.live_program_args {
                command.arg("--live-arg").arg(arg);
            }
        } else {
            command.arg(&self.rr_trace_folder);
        }
        let ct_worker = command
            // M-REC-11: the worker (ct-native-replay) reads
            // $CODETRACER_RUN_ID to compute the socket path; falls
            // back to getppid() only when unset (transitional).
            .env(crate::paths::CODETRACER_RUN_ID_ENV, &self.run_id)
            .stdout(Stdio::null())
            .stderr(Stdio::from(stderr_file))
            .spawn()?;

        let worker_pid = ct_worker.id();
        eprintln!("[rr-worker] spawned worker pid={}", worker_pid);
        self.process = Some(ct_worker);
        if let Err(err) = self.setup_worker_sockets() {
            let worker_stderr = std::fs::read_to_string(&log_path)
                .ok()
                .map(|text| text.trim().to_string())
                .filter(|text| !text.is_empty());
            if let Some(child) = self.process.as_mut() {
                let _ = child.kill();
                let _ = child.wait();
            }
            self.process = None;
            self.stream = None;
            self.active = false;
            let detail = match worker_stderr {
                Some(stderr) => format!("{err}; worker stderr: {stderr}"),
                None => err.to_string(),
            };
            return Err(format!(
                "failed to initialize replay-worker transport for pid {}: {}",
                worker_pid, detail
            )
            .into());
        }
        self.active = true;
        Ok(())
    }

    #[cfg(unix)]
    fn setup_worker_sockets(&mut self) -> Result<(), Box<dyn Error>> {
        // M-REC-11: use the same run-id that was passed to the child
        // via $CODETRACER_RUN_ID in `start`, so spawner and worker
        // compute the same socket path.
        let socket_path = recreator_socket_path("", &self.name, self.index, &self.run_id)?;

        eprintln!("[rr-worker] connecting to socket {}", socket_path.display());

        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            if let Ok(stream) = UnixStream::connect(&socket_path) {
                stream.set_read_timeout(Some(replay_query_timeout()))?;
                self.stream = Some(stream);
                eprintln!("[rr-worker] socket connected");
                return Ok(());
            }

            if Instant::now() >= deadline {
                return Err(format!(
                    "timeout after 10s waiting for worker socket at {}",
                    socket_path.display()
                )
                .into());
            }

            // Check if the worker process is still alive.
            if let Some(ref mut child) = self.process
                && let Some(status) = child.try_wait()?
            {
                return Err(format!("worker process exited with {} before creating socket", status).into());
            }

            thread::sleep(Duration::from_millis(10));
        }
    }

    #[cfg(windows)]
    fn setup_worker_sockets(&mut self) -> Result<(), Box<dyn Error>> {
        let deadline = Instant::now() + Duration::from_secs(10);
        let poll_interval = Duration::from_millis(25);
        let mut last_error: Option<String> = None;
        let manifest_name = format!("ct_native_replay_{}_{}_from_.sock", self.name, self.index);
        let tmp_path = {
            CODETRACER_PATHS
                .lock()
                .map_err(|e| format!("failed to lock CODETRACER_PATHS: {e}"))?
                .tmp_path
                .clone()
        };
        // M-REC-11: the worker's preferred run directory is the one
        // that matches the run-id we reserved in `start` and passed via
        // $CODETRACER_RUN_ID.  We still consult sibling run-* dirs as a
        // best-effort fallback for races between spawn and manifest
        // write.
        let preferred_run_id = self.run_id.clone();
        info!(
            "try to resolve worker endpoint manifest for replay worker: {}",
            manifest_name
        );

        while Instant::now() < deadline {
            {
                let preferred_manifest = tmp_path.join(format!("run-{}", preferred_run_id)).join(&manifest_name);
                if preferred_manifest.exists() {
                    match std::fs::read_to_string(&preferred_manifest) {
                        Ok(payload) => {
                            let endpoint = match serde_json::from_str::<WorkerTransportEndpoint>(&payload) {
                                Ok(endpoint) => endpoint,
                                Err(err) => {
                                    last_error = Some(format!(
                                        "failed to parse worker endpoint manifest {}: {err}",
                                        preferred_manifest.display()
                                    ));
                                    thread::sleep(poll_interval);
                                    continue;
                                }
                            };

                            if endpoint.transport != "tcp" {
                                last_error = Some(format!(
                                    "unsupported worker transport '{}' in manifest {}; expected 'tcp'",
                                    endpoint.transport,
                                    preferred_manifest.display()
                                ));
                                thread::sleep(poll_interval);
                                continue;
                            }
                            if endpoint.address.trim().is_empty() {
                                last_error = Some(format!(
                                    "worker endpoint manifest {} has empty tcp address",
                                    preferred_manifest.display()
                                ));
                                thread::sleep(poll_interval);
                                continue;
                            }

                            match connect_tcp_endpoint_with_timeout(&endpoint.address, Duration::from_millis(250)) {
                                Ok(stream) => {
                                    self.stream = Some(stream);
                                    info!(
                                        "worker stream is now setup via tcp {} using preferred manifest {}",
                                        endpoint.address,
                                        preferred_manifest.display()
                                    );
                                    return Ok(());
                                }
                                Err(err) => {
                                    last_error = Some(format!(
                                        "failed connecting to replay-worker tcp endpoint {} from preferred manifest {}: {}",
                                        endpoint.address,
                                        preferred_manifest.display(),
                                        err
                                    ));
                                }
                            }
                        }
                        Err(err) => {
                            last_error = Some(format!(
                                "failed reading worker endpoint manifest {}: {}",
                                preferred_manifest.display(),
                                err
                            ));
                        }
                    }
                }
            }

            // Fallback: scan sibling run-* dirs whose worker manifest matches our
            // <name>_<index> pair; the preferred run dir was already probed above.
            let mut candidates = Vec::new();
            if let Ok(run_dirs) = std::fs::read_dir(&tmp_path) {
                for run_dir in run_dirs.flatten() {
                    let path = run_dir.path();
                    if !path.is_dir() {
                        continue;
                    }
                    let Some(run_name) = path.file_name().and_then(|n| n.to_str()) else {
                        continue;
                    };
                    if !run_name.starts_with("run-") {
                        continue;
                    }
                    // Skip the preferred run dir (already tried above).
                    if run_name == format!("run-{}", preferred_run_id) {
                        continue;
                    }
                    let manifest_path = path.join(&manifest_name);
                    if manifest_path.exists() {
                        let modified = std::fs::metadata(&manifest_path).and_then(|m| m.modified()).ok();
                        candidates.push((manifest_path, modified));
                    }
                }
            }

            candidates.sort_by_key(|c| std::cmp::Reverse(c.1));

            for (manifest_path, _) in candidates {
                match std::fs::read_to_string(&manifest_path) {
                    Ok(payload) => {
                        let endpoint = match serde_json::from_str::<WorkerTransportEndpoint>(&payload) {
                            Ok(endpoint) => endpoint,
                            Err(err) => {
                                last_error = Some(format!(
                                    "failed to parse worker endpoint manifest {}: {err}",
                                    manifest_path.display()
                                ));
                                continue;
                            }
                        };

                        if endpoint.transport != "tcp" {
                            last_error = Some(format!(
                                "unsupported worker transport '{}' in manifest {}; expected 'tcp'",
                                endpoint.transport,
                                manifest_path.display()
                            ));
                            continue;
                        }
                        if endpoint.address.trim().is_empty() {
                            last_error = Some(format!(
                                "worker endpoint manifest {} has empty tcp address",
                                manifest_path.display()
                            ));
                            continue;
                        }

                        match connect_tcp_endpoint_with_timeout(&endpoint.address, Duration::from_millis(250)) {
                            Ok(stream) => {
                                self.stream = Some(stream);
                                info!(
                                    "worker stream is now setup via tcp {} using manifest {}",
                                    endpoint.address,
                                    manifest_path.display()
                                );
                                return Ok(());
                            }
                            Err(err) => {
                                last_error = Some(format!(
                                    "failed connecting to replay-worker tcp endpoint {} from manifest {}: {}",
                                    endpoint.address,
                                    manifest_path.display(),
                                    err
                                ));
                            }
                        }
                    }
                    Err(err) => {
                        last_error = Some(format!(
                            "failed reading worker endpoint manifest {}: {}",
                            manifest_path.display(),
                            err
                        ));
                    }
                }
            }
            thread::sleep(poll_interval);
        }

        Err(last_error
            .unwrap_or_else(|| {
                format!(
                    "timed out waiting for replay-worker endpoint manifest '{}' under {}",
                    manifest_name,
                    tmp_path.display()
                )
            })
            .into())
    }

    #[cfg(not(any(unix, windows)))]
    fn setup_worker_sockets(&mut self) -> Result<(), Box<dyn Error>> {
        Err("ct-rr worker transport is only supported on Unix and Windows platforms".into())
    }

    // for now: don't return a typed value here, only Ok(raw value) or an error
    #[allow(clippy::expect_used)] // stream must be initialized before dispatch_replay_query is called
    #[cfg(any(unix, windows))]
    pub fn dispatch_replay_query(&mut self, query: ReplayQuery) -> Result<String, Box<dyn Error>> {
        let raw_json = serde_json::to_string(&query)?;

        debug!("send to worker {raw_json}\n");
        self.stream
            .as_mut()
            .expect("valid sending stream")
            .write_all(&format!("{raw_json}\n").into_bytes())?;
        // `clippy::unused_io_amount` catched we need write_all, not write

        let mut res = "".to_string();
        debug!("wait to read");

        let mut reader = BufReader::new(self.stream.as_mut().expect("valid receiving stream"));
        reader.read_line(&mut res).map_err(|e| {
            if e.kind() == std::io::ErrorKind::WouldBlock || e.kind() == std::io::ErrorKind::TimedOut {
                format!(
                    "dispatch_replay_query timed out ({:?}) waiting for worker response to: {raw_json}",
                    replay_query_timeout()
                )
            } else {
                format!("dispatch_replay_query IO error: {e}")
            }
        })?;

        res = String::from(res.trim()); // trim newlines/whitespace!

        debug!("res: `{res}`");

        if res.is_empty() {
            // EOF — the replay worker crashed or disconnected. Mark the
            // worker as inactive so that the next query attempt can restart it,
            // and return a clear error rather than an empty string that would
            // fail JSON parsing downstream.
            self.active = false;
            return Err("ct-native-replay worker disconnected (EOF on response)".into());
        }

        if res.starts_with("error:") {
            return Err(format!("dispatch_replay_query ct rr worker error: {}", res).into());
        }

        // TTD replay workers return JSON error envelopes like:
        //   {"status":"error","code":"...","message":"..."}
        // Detect these so they don't pass through as "success" and cause
        // downstream deserialization failures (e.g. "missing field `path`").
        if res.starts_with('{')
            && let Ok(envelope) = serde_json::from_str::<serde_json::Value>(&res)
            && envelope.get("status").and_then(|v| v.as_str()) == Some("error")
        {
            let code = envelope.get("code").and_then(|v| v.as_str()).unwrap_or("unknown");
            let message = envelope
                .get("message")
                .and_then(|v| v.as_str())
                .unwrap_or("(no message)");
            return Err(format!("dispatch_replay_query ct rr worker error: [{code}] {message}").into());
        }

        Ok(res)
    }

    #[cfg(not(any(unix, windows)))]
    pub fn dispatch_replay_query(&mut self, _query: ReplayQuery) -> Result<String, Box<dyn Error>> {
        Err("ct-rr worker transport is only supported on Unix and Windows platforms".into())
    }
}

impl Drop for ReplayWorker {
    fn drop(&mut self) {
        self.stream = None;
        if let Some(child) = self.process.as_mut() {
            let _ = child.kill();
            let _ = child.wait();
        }
        self.process = None;
        self.active = false;
    }
}

#[cfg(windows)]
fn connect_tcp_endpoint_with_timeout(address: &str, timeout: Duration) -> Result<TcpStream, Box<dyn Error>> {
    use std::net::ToSocketAddrs;

    let mut last_error: Option<String> = None;
    for resolved in address
        .to_socket_addrs()
        .map_err(|e| format!("failed to resolve replay-worker endpoint '{address}': {e}"))?
    {
        match TcpStream::connect_timeout(&resolved, timeout) {
            Ok(stream) => return Ok(stream),
            Err(err) => {
                last_error = Some(format!("{} ({})", resolved, err));
            }
        }
    }

    Err(last_error
        .unwrap_or_else(|| format!("no socket addresses resolved for replay-worker endpoint '{address}'"))
        .into())
}

impl RecreatorReplaySession {
    pub fn new(name: &str, index: usize, ct_rr_args: RecreatorArgs) -> RecreatorReplaySession {
        let mut stable = ReplayWorker::new_with_recording_id(
            name,
            index,
            &ct_rr_args.worker_exe,
            &ct_rr_args.rr_trace_folder,
            &ct_rr_args.recording_id,
        );
        stable.live_program = ct_rr_args.live_program.clone();
        stable.live_program_args = ct_rr_args.live_program_args.clone();
        stable.live_cwd = ct_rr_args.live_cwd.clone();
        stable.live_recording_dir = ct_rr_args.live_recording_dir.clone();
        RecreatorReplaySession {
            name: name.to_string(),
            index,
            // M-REC-11: propagate the trace's recording_id to the
            // worker; empty falls back to the legacy PID rendezvous.
            stable,
            recreator_exe: ct_rr_args.worker_exe.clone(),
            rr_trace_folder: ct_rr_args.rr_trace_folder.clone(),
            last_c_location: None,
        }
    }

    pub fn ensure_active_stable(&mut self) -> Result<(), Box<dyn Error>> {
        // start stable process if not active, store fields, setup ipc? store in stable
        if !self.stable.active {
            eprintln!("[rr-dispatcher] starting worker for '{}'", self.name);
            let res = self.stable.start();
            if let Err(e) = res {
                eprintln!("[rr-dispatcher] worker start FAILED: {:?}", e);
                error!("can't start ct rr worker for {}! error is {:?}", self.name, e);
                return Err(e);
            }
            eprintln!("[rr-dispatcher] worker started successfully");
        }
        // check again:
        if !self.stable.active {
            return Err("stable started, but still not active without an obvious error".into());
        }

        Ok(())
    }

    fn load_location_directly(&mut self) -> Result<Location, Box<dyn Error>> {
        Ok(serde_json::from_str::<Location>(
            &self.stable.dispatch_replay_query(ReplayQuery::LoadLocation)?,
        )?)
    }

    /// Try to load location with sourcemap translation (for Nim).
    /// Falls back to plain LoadLocation if the worker does not support it.
    fn load_location_with_sourcemap(&mut self) -> Result<Location, Box<dyn Error>> {
        match self
            .stable
            .dispatch_replay_query(ReplayQuery::LoadLocationWithSourcemap)
        {
            Ok(response) => {
                let lws = serde_json::from_str::<LocationWithSourcemap>(&response)?;
                // Store the c_location for the frontend's assembly and C views.
                if !lws.c_location.path.is_empty() {
                    self.last_c_location = Some(lws.c_location);
                } else {
                    self.last_c_location = None;
                }
                Ok(lws.location)
            }
            Err(e) => {
                // Fall back to plain LoadLocation if the worker doesn't support
                // the sourcemap query (e.g. older replay workers).
                warn!("LoadLocationWithSourcemap failed ({e}), falling back to LoadLocation");
                self.last_c_location = None;
                self.load_location_directly()
            }
        }
    }
}

impl ReplaySession for RecreatorReplaySession {
    fn load_location(&mut self, _expr_loader: &mut ExprLoader) -> Result<Location, Box<dyn Error>> {
        self.ensure_active_stable()?;
        self.load_location_with_sourcemap()
    }

    fn last_c_location(&self) -> Option<Location> {
        self.last_c_location.clone()
    }

    fn run_to_entry(&mut self) -> Result<(), Box<dyn Error>> {
        self.ensure_active_stable()?;
        let _ok = self.stable.dispatch_replay_query(ReplayQuery::RunToEntry)?;
        Ok(())
    }

    fn load_events(&mut self) -> Result<Events, Box<dyn Error>> {
        self.ensure_active_stable()?;
        let events = serde_json::from_str::<Events>(&self.stable.dispatch_replay_query(ReplayQuery::LoadAllEvents)?)?;
        Ok(events)
        // Ok(Events {
        //     events: vec![],
        //     first_events: vec![],
        //     contents: "".to_string(),
        // })
    }

    fn step(&mut self, action: Action, forward: bool) -> Result<bool, Box<dyn Error>> {
        self.ensure_active_stable()?;
        let res = serde_json::from_str::<bool>(
            &self
                .stable
                .dispatch_replay_query(ReplayQuery::Step { action, forward })?,
        )?;
        Ok(res)
    }

    fn load_locals(&mut self, arg: CtLoadLocalsArguments) -> Result<Vec<VariableWithRecord>, Box<dyn Error>> {
        self.ensure_active_stable()?;
        let res = serde_json::from_str::<Vec<VariableWithRecord>>(
            &self.stable.dispatch_replay_query(ReplayQuery::LoadLocals { arg })?,
        )?;
        Ok(res)
    }

    fn load_value(
        &mut self,
        expression: &str,
        depth_limit: Option<usize>,
        lang: Lang,
    ) -> Result<ValueRecordWithType, Box<dyn Error>> {
        self.ensure_active_stable()?;
        let res = serde_json::from_str::<ValueRecordWithType>(&self.stable.dispatch_replay_query(
            ReplayQuery::LoadValue {
                expression: expression.to_string(),
                depth_limit,
                lang,
            },
        )?)?;
        Ok(res)
    }

    fn load_return_value(
        &mut self,
        depth_limit: Option<usize>,
        lang: Lang,
    ) -> Result<ValueRecordWithType, Box<dyn Error>> {
        self.ensure_active_stable()?;
        let res = serde_json::from_str::<ValueRecordWithType>(
            &self
                .stable
                .dispatch_replay_query(ReplayQuery::LoadReturnValue { depth_limit, lang })?,
        )?;
        Ok(res)
    }

    fn load_step_events(&mut self, _step_id: StepId, _exact: bool) -> Vec<DbRecordEvent> {
        // TODO: maybe cache events directly in replay for now, and use the same logic for them as in Db?
        // or directly embed Db? or separate events in a separate EventList?
        warn!("load_step_events not implemented for rr traces");
        vec![]
    }

    fn load_callstack(&mut self) -> Result<Vec<CallLine>, Box<dyn Error>> {
        self.ensure_active_stable()?;
        let res =
            serde_json::from_str::<Vec<CallLine>>(&self.stable.dispatch_replay_query(ReplayQuery::LoadCallstack)?)?;
        Ok(res)
    }

    fn load_history(&mut self, arg: &LoadHistoryArg) -> Result<(Vec<HistoryResultWithRecord>, i64), Box<dyn Error>> {
        self.ensure_active_stable()?;
        let res = serde_json::from_str::<(Vec<HistoryResultWithRecord>, i64)>(
            &self
                .stable
                .dispatch_replay_query(ReplayQuery::LoadHistory { arg: arg.clone() })?,
        )?;
        Ok(res)
    }

    fn jump_to(&mut self, _step_id: StepId) -> Result<bool, Box<dyn Error>> {
        // TODO
        error!("TODO rr jump_to: for now run to entry");
        self.run_to_entry()?;
        Ok(true)
        // todo!()
    }

    fn location_jump(&mut self, location: &Location) -> Result<(), Box<dyn Error>> {
        self.ensure_active_stable()?;
        let _ = self.stable.dispatch_replay_query(ReplayQuery::LocationJump {
            location: location.clone(),
        })?;
        Ok(())
    }

    fn add_breakpoint(&mut self, path: &str, line: i64) -> Result<Breakpoint, Box<dyn Error>> {
        self.ensure_active_stable()?;
        let breakpoint =
            serde_json::from_str::<Breakpoint>(&self.stable.dispatch_replay_query(ReplayQuery::AddBreakpoint {
                path: path.to_string(),
                line,
            })?)?;
        Ok(breakpoint)
    }

    fn delete_breakpoint(&mut self, breakpoint: &Breakpoint) -> Result<bool, Box<dyn Error>> {
        self.ensure_active_stable()?;
        Ok(serde_json::from_str::<bool>(&self.stable.dispatch_replay_query(
            ReplayQuery::DeleteBreakpoint {
                breakpoint: breakpoint.clone(),
            },
        )?)?)
    }

    fn delete_breakpoints(&mut self) -> Result<bool, Box<dyn Error>> {
        self.ensure_active_stable()?;
        Ok(serde_json::from_str::<bool>(
            &self.stable.dispatch_replay_query(ReplayQuery::DeleteBreakpoints)?,
        )?)
    }

    fn toggle_breakpoint(&mut self, breakpoint: &Breakpoint) -> Result<Breakpoint, Box<dyn Error>> {
        self.ensure_active_stable()?;
        Ok(serde_json::from_str::<Breakpoint>(
            &self.stable.dispatch_replay_query(ReplayQuery::ToggleBreakpoint {
                breakpoint: breakpoint.clone(),
            })?,
        )?)
    }

    fn enable_breakpoints(&mut self) -> Result<(), Box<dyn Error>> {
        self.ensure_active_stable()?;
        let _ = self.stable.dispatch_replay_query(ReplayQuery::EnableBreakpoints)?;
        Ok(())
    }

    fn disable_breakpoints(&mut self) -> Result<(), Box<dyn Error>> {
        self.ensure_active_stable()?;
        let _ = self.stable.dispatch_replay_query(ReplayQuery::DisableBreakpoints)?;
        Ok(())
    }

    fn jump_to_call(&mut self, location: &Location) -> Result<Location, Box<dyn Error>> {
        self.ensure_active_stable()?;
        Ok(serde_json::from_str::<Location>(&self.stable.dispatch_replay_query(
            ReplayQuery::JumpToCall {
                location: location.clone(),
            },
        )?)?)
    }

    fn event_jump(&mut self, event: &ProgramEvent) -> Result<bool, Box<dyn Error>> {
        self.ensure_active_stable()?;
        Ok(serde_json::from_str::<bool>(&self.stable.dispatch_replay_query(
            ReplayQuery::EventJump {
                program_event: event.clone(),
            },
        )?)?)
    }

    fn callstack_jump(&mut self, depth: usize) -> Result<(), Box<dyn Error>> {
        self.ensure_active_stable()?;
        self.stable
            .dispatch_replay_query(ReplayQuery::CallstackJump { depth })?;
        Ok(())
    }

    #[allow(clippy::expect_used)] // load_location_directly should succeed after ensure_active_stable
    fn current_step_id(&mut self) -> StepId {
        // cache location or step_id and return
        // OR always load from worker
        // TODO: return result or do something else or cache ?
        match self.ensure_active_stable() {
            Ok(_) => {
                let location = self.load_location_directly().expect("access to step_id");
                StepId(location.rr_ticks.0)
            }
            Err(e) => {
                error!("current_step_id: can't ensure active worker: error: {e:?}");
                // hard to change all callsites to handle result for now
                //   but not sure if NO_STEP_ID is much better: however this is only for rr cases
                //   so we *should* try to not directly index into db.steps with it even if not NO_STEP_ID?
                error!("  for now returning NO_STEP_ID");
                StepId(NO_STEP_ID)
            }
        }
    }

    fn tracepoint_jump(&mut self, event: &ProgramEvent) -> Result<(), Box<dyn Error>> {
        self.ensure_active_stable()?;
        self.stable
            .dispatch_replay_query(ReplayQuery::TracepointJump { event: event.clone() })?;
        Ok(())
    }

    fn evaluate_call_expression(
        &mut self,
        call_expression: &str,
        _lang: Lang,
    ) -> Result<ValueRecordWithType, Box<dyn Error>> {
        self.ensure_active_stable()?;
        let request = TtdTracepointEvalRequest {
            mode: TtdTracepointEvalMode::EmulatedFunction,
            expression: None,
            function_call: Some(TtdTracepointFunctionCallRequest {
                target_expression: String::new(),
                call_expression: Some(call_expression.to_string()),
                signature: None,
                arguments: vec![],
                return_address: None,
            }),
        };

        let response_json = self
            .stable
            .dispatch_replay_query(ReplayQuery::TtdTracepointEvaluate { request })?;
        let response: TtdTracepointEvalResponseEnvelope = serde_json::from_str(&response_json)?;

        if let Some(diag) = response.diagnostic {
            return Err(format!(
                "tracepoint call evaluation failed: {}{}",
                diag.message,
                diag.detail
                    .as_ref()
                    .map(|detail| format!(" ({detail})"))
                    .unwrap_or_default()
            )
            .into());
        }

        if let Some(value) = tracepoint_response_value(&response) {
            return Ok(value);
        }

        Err("tracepoint call evaluation did not return a value".into())
    }

    fn recording_head(&mut self) -> Result<u64, Box<dyn Error>> {
        self.ensure_active_stable()?;
        let response = self.stable.dispatch_replay_query(ReplayQuery::GetRecordingHead)?;
        parse_recording_head_response(&response)
    }

    fn restore_at(
        &mut self,
        geid: u64,
        tid: Option<u32>,
        tick: Option<u64>,
        phase: Option<String>,
    ) -> Result<bool, Box<dyn Error>> {
        self.ensure_active_stable()?;
        let response = self
            .stable
            .dispatch_replay_query(ReplayQuery::RestoreAt { geid, tid, tick, phase })?;
        parse_bool_or_status_response(&response)
    }

    fn seek_to_geid(&mut self, geid: u64) -> Result<bool, Box<dyn Error>> {
        self.ensure_active_stable()?;
        let response = self.stable.dispatch_replay_query(ReplayQuery::SeekToGeid { geid })?;
        parse_bool_or_status_response(&response)
    }

    /// Forward `GetProcessInfo` to the replay worker.
    ///
    /// The native-backend worker either shells out to `rr ps` (for RR traces)
    /// or reads the recorded process table (for in-process MCR). On any
    /// failure we fall back to a synthetic single-process list so the DAP
    /// `threads` request still returns a non-empty array.
    fn list_processes(&mut self) -> Result<Vec<crate::task::ProcessInfo>, Box<dyn Error>> {
        self.ensure_active_stable()?;
        let response = self.stable.dispatch_replay_query(ReplayQuery::GetProcessInfo)?;
        let processes: Vec<crate::task::ProcessInfo> =
            serde_json::from_str(&response).map_err(|e| -> Box<dyn Error> {
                format!("GetProcessInfo: failed to parse worker response: {e}; payload: {response}").into()
            })?;
        if processes.is_empty() {
            // Worker returned `[]` (rr ps unavailable or recording metadata
            // missing). Fall back to one synthetic process so the DAP layer
            // still surfaces at least one thread to the client.
            return Ok(vec![crate::task::ProcessInfo {
                pid: 0,
                ppid: 0,
                exit_code: None,
                command: "main".to_string(),
            }]);
        }
        Ok(processes)
    }
}

fn parse_recording_head_response(response: &str) -> Result<u64, Box<dyn Error>> {
    if let Ok(value) = serde_json::from_str::<serde_json::Value>(response) {
        for key in ["rrTicks", "recordingHead", "head", "geid"] {
            if let Some(head) = value.get(key).and_then(|v| v.as_u64()) {
                return Ok(head);
            }
        }
        if let Some(text) = value.as_str()
            && let Some(head) = parse_geid_text(text)
        {
            return Ok(head);
        }
    }

    if let Some(head) = parse_geid_text(response) {
        return Ok(head);
    }

    Err(format!("GetRecordingHead: could not parse worker response: {response}").into())
}

fn parse_bool_or_status_response(response: &str) -> Result<bool, Box<dyn Error>> {
    if let Ok(value) = serde_json::from_str::<serde_json::Value>(response) {
        if let Some(b) = value.as_bool() {
            return Ok(b);
        }
        if let Some(status) = value.get("status").and_then(|v| v.as_str()) {
            return Ok(status == "ok" || status == "stopped");
        }
        if value.get("error").is_some() {
            return Ok(false);
        }
    }

    let trimmed = response.trim();
    Ok(trimmed == "true"
        || trimmed.starts_with("T05")
        || trimmed.starts_with("T0")
        || trimmed.contains("\"status\":\"ok\""))
}

fn parse_geid_text(text: &str) -> Option<u64> {
    let marker = "geid:";
    let start = text.find(marker)? + marker.len();
    let digits: String = text[start..].chars().take_while(|ch| ch.is_ascii_digit()).collect();
    digits.parse().ok()
}

fn tracepoint_response_value(response: &TtdTracepointEvalResponseEnvelope) -> Option<ValueRecordWithType> {
    response
        .value
        .clone()
        .or_else(|| response.return_value.clone())
        .or_else(|| tracepoint_return_value_from_class(response))
}

fn tracepoint_return_value_from_class(response: &TtdTracepointEvalResponseEnvelope) -> Option<ValueRecordWithType> {
    let raw = response.return_value_u64?;
    let class = response.return_value_class.unwrap_or(TtdTracepointValueClass::U64);

    let (kind, lang_type) = match class {
        TtdTracepointValueClass::Void => return None,
        TtdTracepointValueClass::Bool => (TypeKind::Bool, "bool"),
        TtdTracepointValueClass::I64 => (TypeKind::Int, "i64"),
        TtdTracepointValueClass::U64 => (TypeKind::Int, "u64"),
        TtdTracepointValueClass::Pointer => (TypeKind::Raw, "pointer"),
    };

    let typ = TypeRecord {
        kind,
        lang_type: lang_type.to_string(),
        specific_info: TypeSpecificInfo::None,
    };

    Some(match class {
        TtdTracepointValueClass::Void => return None,
        TtdTracepointValueClass::Bool => ValueRecordWithType::Bool { b: raw != 0, typ },
        TtdTracepointValueClass::I64 => {
            let signed = i64::from_ne_bytes(raw.to_ne_bytes());
            ValueRecordWithType::Int { i: signed, typ }
        }
        TtdTracepointValueClass::U64 => ValueRecordWithType::Int { i: raw as i64, typ },
        TtdTracepointValueClass::Pointer => ValueRecordWithType::Raw {
            r: format!("0x{raw:016x}"),
            typ,
        },
    })
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use codetracer_trace_types::{TypeKind, TypeRecord, TypeSpecificInfo};

    #[test]
    fn tracepoint_return_value_prefers_complex_payload() {
        let typ = TypeRecord {
            kind: TypeKind::Struct,
            lang_type: "Pair".to_string(),
            specific_info: TypeSpecificInfo::Struct { fields: vec![] },
        };
        let complex = ValueRecordWithType::Struct {
            field_values: vec![],
            typ: typ.clone(),
        };
        let response = TtdTracepointEvalResponseEnvelope {
            mode: TtdTracepointEvalMode::EmulatedFunction,
            replay_state_preserved: true,
            value: None,
            return_value: Some(complex.clone()),
            return_value_class: Some(TtdTracepointValueClass::U64),
            return_value_u64: Some(123),
            invocation: None,
            diagnostic: None,
        };

        let derived = tracepoint_response_value(&response).expect("value");
        assert_eq!(
            serde_json::to_string(&derived).unwrap(),
            serde_json::to_string(&complex).unwrap()
        );
    }

    #[test]
    fn tracepoint_return_value_bool() {
        let response = TtdTracepointEvalResponseEnvelope {
            mode: TtdTracepointEvalMode::EmulatedFunction,
            replay_state_preserved: true,
            value: None,
            return_value: None,
            return_value_class: Some(TtdTracepointValueClass::Bool),
            return_value_u64: Some(1),
            invocation: None,
            diagnostic: None,
        };

        let value = tracepoint_return_value_from_class(&response).expect("bool value");
        match value {
            ValueRecordWithType::Bool { b, .. } => assert!(b),
            other => panic!("unexpected value type: {other:?}"),
        }
    }

    #[test]
    fn tracepoint_return_value_i64() {
        let response = TtdTracepointEvalResponseEnvelope {
            mode: TtdTracepointEvalMode::EmulatedFunction,
            replay_state_preserved: true,
            value: None,
            return_value: None,
            return_value_class: Some(TtdTracepointValueClass::I64),
            return_value_u64: Some(u64::MAX),
            invocation: None,
            diagnostic: None,
        };

        let value = tracepoint_return_value_from_class(&response).expect("i64 value");
        match value {
            ValueRecordWithType::Int { i, .. } => assert_eq!(i, -1),
            other => panic!("unexpected value type: {other:?}"),
        }
    }

    #[test]
    fn tracepoint_return_value_pointer() {
        let response = TtdTracepointEvalResponseEnvelope {
            mode: TtdTracepointEvalMode::EmulatedFunction,
            replay_state_preserved: true,
            value: None,
            return_value: None,
            return_value_class: Some(TtdTracepointValueClass::Pointer),
            return_value_u64: Some(0x1234),
            invocation: None,
            diagnostic: None,
        };

        let value = tracepoint_return_value_from_class(&response).expect("pointer value");
        match value {
            ValueRecordWithType::Raw { r, .. } => assert_eq!(r, "0x0000000000001234"),
            other => panic!("unexpected value type: {other:?}"),
        }
    }
}
