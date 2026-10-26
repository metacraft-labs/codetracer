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

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use codetracer_trace_types::StepId;
use log::{debug, error, info, warn};
use serde::Deserialize;

use crate::ctfs_trace_reader::block_overlay::{CtfsBlockOverlay, FileBlockSink, OverlayMode};
use crate::ctfs_trace_reader::ctfs_container::LocalFileSource;
use crate::ctfs_trace_reader::materialization_cache::{
    EnsureOutcome, MaterializationCache, MaterializedInterval, Recreator,
};
use crate::ctfs_trace_reader::server_prep_encoding::{decode_linehits, decode_memwrites};
use crate::db::DbRecordEvent;
use crate::expr_loader::ExprLoader;
use crate::lang::Lang;
#[cfg(windows)]
use crate::paths::CODETRACER_PATHS;
use crate::paths::log_path_in;
#[cfg(unix)]
use crate::paths::recreator_socket_path_in;
use crate::query::{
    MaterializeIntervalResponse, ReplayQuery, TtdTracepointEvalMode, TtdTracepointEvalRequest,
    TtdTracepointEvalResponseEnvelope, TtdTracepointFunctionCallRequest, TtdTracepointValueClass,
};
use crate::replay::ReplaySession;
use crate::task::{
    Action, Breakpoint, CallLine, CtLoadLocalsArguments, Events, HistoryResultWithRecord, LoadHistoryArg, Location,
    LocationWithSourcemap, NO_STEP_ID, ProgramEvent, VariableWithRecord,
};
use crate::value::ValueRecordWithType;

/// The licensing stop-reason code `ct-native-replay` writes when the free
/// tier's daily replay quota is exhausted.
///
/// Emitted by `codetracer-native-backend`'s
/// `src/licensing/cli.rs::emit_replay_start_block`, which writes
/// `{"result":"blocked","stop_reason":{"code":"daily_replay_limit_reached",
/// "count":<n>,"limit":<n>}}` to **stderr** and then exits with status 3.
/// `codetracer-native-backend/tests/licensing_integration_test.rs::
/// e2e_free_license_still_uses_daily_replay_limit` pins both the exit code and
/// the JSON shape, so this constant is a cross-repo contract: changing it here
/// without changing it there silently reverts issue #689.
pub const DAILY_REPLAY_LIMIT_REACHED: &str = "daily_replay_limit_reached";

/// The machine-readable reason a replay worker refused to start, parsed out of
/// the JSON line its licensing module writes to stderr before exiting.
///
/// `count` / `limit` are `Option` because only some stop reasons carry them
/// (the duration cap, for instance, carries a `session_kind` instead), and a
/// reader that requires them would drop every other reason on the floor.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct WorkerStopReason {
    /// The stable machine code, e.g. `daily_replay_limit_reached`.
    pub code: String,
    /// Replays already consumed today, when the reason is quota-shaped.
    #[serde(default)]
    pub count: Option<u64>,
    /// The daily allowance that was exceeded, when the reason is quota-shaped.
    #[serde(default)]
    pub limit: Option<u64>,
}

/// The envelope the worker writes around a [`WorkerStopReason`].
///
/// Deliberately tolerant: the worker interleaves free-form log lines with this
/// JSON, so every stderr line is attempted and non-JSON lines are skipped.
#[derive(Debug, Deserialize)]
struct WorkerStopLine {
    stop_reason: Option<WorkerStopReason>,
}

/// A replay worker that refused to start, carrying the reason when the worker
/// gave one.
///
/// This exists so callers can branch on *why* the launch failed instead of
/// substring-matching a formatted string. Before it, every worker refusal —
/// including a licensing quota block — reached the caller as
/// `"worker process exited with <status> before creating socket"`, which is
/// issue #689's cryptic message.
#[derive(Debug, Clone)]
pub struct ReplayWorkerStartError {
    /// The parsed stop reason, when the worker wrote a machine-readable one.
    pub stop_reason: Option<WorkerStopReason>,
    /// The untyped detail (transport error plus raw worker stderr), kept for
    /// diagnostics and for every failure the worker does not classify.
    pub detail: String,
    /// The pid of the worker that failed, for correlating with its stderr log.
    pub worker_pid: u32,
}

impl ReplayWorkerStartError {
    /// The machine code the worker reported, if any.
    pub fn code(&self) -> Option<&str> {
        self.stop_reason.as_ref().map(|reason| reason.code.as_str())
    }

    /// True when the worker refused because the free-tier daily replay quota
    /// is exhausted (issue #689).
    pub fn is_daily_replay_limit_reached(&self) -> bool {
        self.code() == Some(DAILY_REPLAY_LIMIT_REACHED)
    }
}

impl std::fmt::Display for ReplayWorkerStartError {
    /// The quota case renders the **only** user-facing wording the licensing
    /// spec specifies for the free-tier replay limit —
    /// `codetracer-specs/Planned-Features/CodeTracer-End-User-Licensing.md`
    /// §3.6 step 4. The limit is interpolated from the worker's own JSON
    /// rather than hardcoded so the sentence cannot go stale against
    /// `DEFAULT_FREE_TIER_DAILY_LIMIT`. No second vocabulary is invented here:
    /// the counters stay in the struct fields for whoever builds the GUI
    /// surface, which is not yet specified.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match &self.stop_reason {
            Some(reason) if reason.code == DAILY_REPLAY_LIMIT_REACHED => {
                let limit = reason.limit.unwrap_or(0);
                write!(
                    f,
                    "Free tier: {limit} replays per day. \
                     Visit https://codetracer.com/pricing to upgrade."
                )
            }
            Some(reason) => write!(
                f,
                "replay worker for pid {} refused to start: {}",
                self.worker_pid, reason.code
            ),
            None => write!(
                f,
                "failed to initialize replay-worker transport for pid {}: {}",
                self.worker_pid, self.detail
            ),
        }
    }
}

impl Error for ReplayWorkerStartError {}

/// A replay worker that went away while a query was in flight: it closed its
/// connection without answering, or the connection broke under the query.
///
/// Returned by [`ReplayWorker::dispatch_replay_query`] instead of a bare
/// string so that a caller can tell "the worker answered with an error" (the
/// worker is still there and still positioned) from "the worker is gone" (its
/// replay position is lost with it). The flow preloader depends on that
/// difference: a flow whose worker died must be reported as a failure naming
/// the worker, not completed from a fresh worker that knows nothing of the
/// position the flow was walking (codetracer-pm issue 2026-10-21 "Rust rr flow
/// worker segfaults in LLDB, so the flow finds no variables").
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReplayWorkerDied {
    /// The worker's name (`stable`, `flow`, …), as passed to `replay-worker --name`.
    pub name: String,
    /// The worker's index, as passed to `replay-worker --index`.
    pub index: usize,
    /// The worker's process id, when the session spawned it.
    pub pid: Option<u32>,
    /// The kind of query that was in flight (`JumpToCall`, `Step`, …).
    pub query: String,
    /// How the process ended, as far as it could be observed: its exit
    /// status (`signal: 11 (SIGSEGV) (core dumped)`, `exit status: 3`) or why
    /// none is known.
    pub exit: String,
}

impl std::fmt::Display for ReplayWorkerDied {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "the `{}` replay worker (index {}", self.name, self.index)?;
        if let Some(pid) = self.pid {
            write!(f, ", pid {pid}")?;
        }
        write!(f, ") died while answering {}: {}", self.query, self.exit)
    }
}

impl Error for ReplayWorkerDied {}

/// How long to wait for a worker that closed its connection to finish
/// exiting, so its exit status can be reported.
///
/// This bounds an unusual case, not the common one. A worker killed by a
/// signal has normally exited completely by the time its connection reads
/// EOF: Linux writes the core dump before it closes the dying process's
/// files, so the socket closes after the core is written and the process can
/// be reaped at once (measured 2026-10-23 with `systemd-coredump`: EOF 1.2 s
/// after a SIGSEGV that dumped 250 MB, and `waitpid` succeeded immediately
/// after it). The wait matters for a worker that closed its end and is still
/// shutting down, for example tearing down LLDB and its `rr` replay. It is
/// stopped after the grace period, so a worker that never exits cannot hold
/// the session. Stopping it earlier would lose its exit status, the evidence
/// the death report carries.
const WORKER_EXIT_GRACE: Duration = Duration::from_secs(10);

/// The kind of a serialized replay query, for naming it in a diagnostic
/// without repeating its payload: `ReplayQuery` is internally tagged
/// (`#[serde(tag = "kind")]`), so `{"kind":"JumpToCall",…}` → `JumpToCall`.
fn replay_query_kind(raw_json: &str) -> String {
    serde_json::from_str::<serde_json::Value>(raw_json)
        .ok()
        .and_then(|query| query.get("kind")?.as_str().map(str::to_string))
        .unwrap_or_else(|| "a replay query".to_string())
}

/// Scan a worker's stderr for the licensing module's machine-readable stop
/// reason.
///
/// Returns the **last** parseable reason: the worker may log several
/// decisions and the most recent one is the one that ended the process.
/// Lines that are not JSON, or are JSON without a `stop_reason`, are skipped
/// rather than treated as failures — the worker's stderr is a mixed stream.
pub fn parse_worker_stop_reason(stderr: &str) -> Option<WorkerStopReason> {
    stderr
        .lines()
        .filter_map(|line| {
            let trimmed = line.trim();
            if !trimmed.starts_with('{') {
                return None;
            }
            serde_json::from_str::<WorkerStopLine>(trimmed)
                .ok()
                .and_then(|parsed| parsed.stop_reason)
        })
        .next_back()
}

fn replay_query_timeout() -> Duration {
    std::env::var("CODETRACER_REPLAY_QUERY_TIMEOUT_SECS")
        .ok()
        .and_then(|raw| raw.parse::<u64>().ok())
        .filter(|seconds| *seconds > 0)
        .map(Duration::from_secs)
        .unwrap_or_else(|| Duration::from_secs(10))
}

fn replay_worker_startup_timeout() -> Duration {
    std::env::var("CODETRACER_REPLAY_WORKER_STARTUP_TIMEOUT_SECS")
        .ok()
        .and_then(|raw| raw.parse::<u64>().ok())
        .filter(|seconds| *seconds > 0)
        .map(Duration::from_secs)
        .unwrap_or_else(|| replay_query_timeout().max(Duration::from_secs(30)))
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
    materialization_cache: MaterializationCache,
    materialization_cache_ctfs_path: Option<PathBuf>,
    /// Whether a query after the worker died may start a replacement. See
    /// [`RecreatorReplaySession::without_respawn_after_worker_death`].
    respawn_after_worker_death: bool,
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
    /// The runtime base directory this worker's run directory (its socket
    /// and log) is under, chosen by `start` so that the socket fits in
    /// `sun_path` (`paths::worker_runtime_base_dir`) and handed to the
    /// worker as `$CODETRACER_RUNTIME_DIR`.  Empty before `start`.
    runtime_dir: PathBuf,
    /// M-REC-11: the trace's UUIDv7 — used by `start` to reserve a
    /// unique-within-this-process `run_id`.  May be empty for callers
    /// that have not yet been migrated; in that case the worker falls
    /// back to the legacy PID rendezvous.
    recording_id: String,
    process: Option<Child>,
    stream: Option<WorkerStream>,
    /// How this worker last died with a query in flight, until a later
    /// [`ReplayWorker::start`] replaces it. See [`ReplayWorkerDied`].
    last_death: Option<ReplayWorkerDied>,
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

/// The `CT_COOP_QUERY=1` route of [`ReplayWorker::start`]: the worker is
/// `ct-mcr replay-worker --coop-query`, taken from `CT_COOP_RECREATOR` (or
/// the worker executable when unset), with `CT_COOP_PROGRAM` /
/// `CT_COOP_FUNC` as its `--coop-program` / `--coop-func`.
#[derive(Debug, Default, Clone)]
struct CoopQueryArgs {
    exe: Option<PathBuf>,
    program: Option<String>,
    func: Option<String>,
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
            runtime_dir: PathBuf::new(),
            recording_id: recording_id.to_string(),
            process: None,
            stream: None,
            last_death: None,
        }
    }

    /// The `replay-worker` command `start` runs for this worker: program and
    /// arguments, before `start` adds its environment and standard streams.
    /// `coop` is the `CT_COOP_QUERY` route, when it is asked for.
    fn worker_command(&self, coop: Option<&CoopQueryArgs>) -> Command {
        let exe_path = coop
            .and_then(|coop| coop.exe.clone())
            .unwrap_or_else(|| self.recreator_exe.clone());

        let mut command = Command::new(&exe_path);
        command
            .arg("replay-worker")
            .arg("--name")
            .arg(&self.name)
            .arg("--index")
            .arg(self.index.to_string());
        // The worker must not outlive this process. db-backend starts it as
        // a plain child and connects to its socket afterwards; a db-backend
        // that dies (or is killed) before connecting used to leave the worker
        // waiting in `accept` forever, with its `ct-mcr debugserver` or
        // `rr replay` child (codetracer-pm issue
        // `2026-10-22-orphaned-mcr-replay-worker-waits-in-accept-after-its-replay-server-is-gone.md`).
        // With `--parent-pid <this process>` the worker, while nothing is
        // connected, exits once this process is no longer its parent
        // (codetracer-pm `spec/CLI/ct-native-replay/README.md`,
        // `replay-worker` § "Lifetime before db-backend connects"). The
        // `CT_COOP_QUERY` route's `ct-mcr replay-worker` takes the same
        // option (`spec/CLI/ct-mcr/replay-worker.md`, "Lifetime of the query
        // server"). POSIX only: the Windows workers do not take it, and
        // `ct-mcr replay-worker` refuses it there.
        #[cfg(unix)]
        command.arg("--parent-pid").arg(std::process::id().to_string());
        if let Some(coop) = coop {
            command.arg("--coop-query");
            if let Some(program) = &coop.program {
                command.arg("--coop-program").arg(program);
            }
            if let Some(func) = &coop.func {
                command.arg("--coop-func").arg(func);
            }
            command.arg(&self.rr_trace_folder);
        } else if let Some(program) = &self.live_program {
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
        command
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
        //
        // The base directory is chosen here, before the worker exists, so
        // that its socket fits in `sun_path`; both sides then use it (see
        // `paths::worker_runtime_base_dir`).
        let runtime_dir = crate::paths::runtime_base_dir()?;
        #[cfg(unix)]
        let runtime_dir = crate::paths::worker_runtime_base_dir(
            runtime_dir,
            &self.run_id,
            &crate::paths::recreator_socket_file_name("", &self.name, self.index),
        )?;
        self.runtime_dir = runtime_dir;
        let log_path = log_path_in(
            &self.runtime_dir,
            "ct-native-replay",
            &self.name,
            self.index,
            &self.run_id,
        )?;
        info!("worker stderr log: {}", log_path.display());
        let stderr_file = std::fs::File::create(&log_path)?;

        // Pillar-E Option-B: when the flow-test harness requests the
        // cooperative-symmetric query server (CT_COOP_QUERY=1), spawn the
        // recorder's `ct-mcr replay-worker --coop-query` instead of the
        // default `ct-native-replay` DYLD replay (which diverges/hangs on the
        // Rust trace).  The cooperative worker brings the SAME cooperatively-
        // linked program up symmetrically (no divergence), stops held at the
        // flow function, and answers the same JSON ReplayQuery protocol with
        // REAL values read from the held child's registers + memory.  The
        // coop env vars (CT_COOP_PROGRAM / CT_COOP_FUNC / CT_COOP_SOURCE) are
        // inherited by the child automatically.
        let coop = (std::env::var("CT_COOP_QUERY").as_deref() == Ok("1")).then(|| CoopQueryArgs {
            exe: std::env::var("CT_COOP_RECREATOR").ok().map(PathBuf::from),
            program: std::env::var("CT_COOP_PROGRAM").ok(),
            func: std::env::var("CT_COOP_FUNC").ok(),
        });
        let mut command = self.worker_command(coop.as_ref());
        // The directory the worker creates its socket in is the one
        // `setup_worker_sockets` connects to only if both resolve the same
        // base directory; name it to the worker rather than rely on that
        // (see `paths::runtime_base_dir`).
        let runtime_dir = self.runtime_dir.clone();
        let ct_worker = command
            // M-REC-11: the worker (ct-native-replay) reads
            // $CODETRACER_RUN_ID to compute the socket path; falls
            // back to getppid() only when unset (transitional).
            .env(crate::paths::CODETRACER_RUN_ID_ENV, &self.run_id)
            .env(crate::paths::CODETRACER_RUNTIME_DIR_ENV, &runtime_dir)
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
            // #689: the worker's stderr is not just a diagnostic blob — when
            // the licensing module refuses the replay it carries a
            // machine-readable stop reason. Parse it so the caller gets a
            // typed refusal instead of "worker process exited with <status>
            // before creating socket", which told the user nothing about the
            // quota they had hit.
            let stop_reason = worker_stderr.as_deref().and_then(parse_worker_stop_reason);
            let detail = match &worker_stderr {
                Some(stderr) => format!("{err}; worker stderr: {stderr}"),
                None => err.to_string(),
            };
            if let Some(reason) = &stop_reason {
                warn!(
                    "replay worker pid {worker_pid} refused to start with stop reason {reason:?}; \
                     raw detail: {detail}"
                );
            }
            return Err(Box::new(ReplayWorkerStartError {
                stop_reason,
                detail,
                worker_pid,
            }));
        }
        self.active = true;
        // A fresh worker replaces the one that died: the death no longer
        // describes this worker.
        self.last_death = None;
        Ok(())
    }

    #[cfg(unix)]
    fn setup_worker_sockets(&mut self) -> Result<(), Box<dyn Error>> {
        // M-REC-11: use the same run-id that was passed to the child
        // via $CODETRACER_RUN_ID in `start`, so spawner and worker
        // compute the same socket path.
        let socket_path = recreator_socket_path_in(&self.runtime_dir, "", &self.name, self.index, &self.run_id)?;

        eprintln!("[rr-worker] connecting to socket {}", socket_path.display());

        let startup_timeout = replay_worker_startup_timeout();
        let deadline = Instant::now() + startup_timeout;
        loop {
            if let Ok(stream) = UnixStream::connect(&socket_path) {
                stream.set_read_timeout(Some(replay_query_timeout()))?;
                self.stream = Some(stream);
                eprintln!("[rr-worker] socket connected");
                return Ok(());
            }

            if Instant::now() >= deadline {
                return Err(format!(
                    "timeout after {}s waiting for worker socket at {}",
                    startup_timeout.as_secs(),
                    socket_path.display(),
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
        let startup_timeout = replay_worker_startup_timeout();
        let deadline = Instant::now() + startup_timeout;
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
    #[cfg(any(unix, windows))]
    pub fn dispatch_replay_query(&mut self, query: ReplayQuery) -> Result<String, Box<dyn Error>> {
        let raw_json = serde_json::to_string(&query)?;

        let Some(stream) = self.stream.as_mut() else {
            return Err(format!("the replay worker is not connected; cannot send: {raw_json}").into());
        };

        debug!("send to worker {raw_json}\n");
        // `clippy::unused_io_amount` catched we need write_all, not write
        if let Err(e) = stream.write_all(&format!("{raw_json}\n").into_bytes()) {
            // The worker's end of the socket is gone (EPIPE / ECONNRESET): it
            // died after answering the previous query.
            return Err(Box::new(
                self.record_death(&raw_json, &format!("sending the query failed ({e})")),
            ));
        }

        let mut res = "".to_string();
        debug!("wait to read");

        let read_result = BufReader::new(stream).read_line(&mut res);
        if let Err(e) = read_result {
            // The protocol pairs answers with queries by order alone. An
            // answer that did not arrive is still owed: the worker writes it
            // whenever it finishes, and the next query would read it as its
            // own. Nothing sent on this connection can be trusted any more,
            // so it is closed and the worker stopped; the next query starts a
            // fresh one.
            self.abandon_connection();
            return Err(
                if e.kind() == std::io::ErrorKind::WouldBlock || e.kind() == std::io::ErrorKind::TimedOut {
                    format!(
                        "dispatch_replay_query timed out ({:?}) waiting for worker response to: {raw_json}",
                        replay_query_timeout()
                    )
                } else {
                    format!("dispatch_replay_query IO error: {e}")
                }
                .into(),
            );
        }

        res = String::from(res.trim()); // trim newlines/whitespace!

        debug!("res: `{res}`");

        if res.is_empty() {
            // EOF — the replay worker crashed or disconnected without
            // answering. It is marked inactive, so the next query attempt can
            // restart it (a session may refuse that, see
            // `RecreatorReplaySession::without_respawn_after_worker_death`),
            // and the error names the worker and how its process ended rather
            // than leaving an empty string to fail JSON parsing downstream.
            return Err(Box::new(
                self.record_death(&raw_json, "it closed its connection without answering"),
            ));
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

impl ReplayWorker {
    /// How this worker last died with a query in flight, if it has not been
    /// restarted since.
    pub fn last_death(&self) -> Option<&ReplayWorkerDied> {
        self.last_death.as_ref()
    }

    /// Record that the worker went away while answering `raw_json`: drop the
    /// connection, reap the process to learn how it ended, and remember the
    /// death (see [`ReplayWorkerDied`]). `connection` says what was observed
    /// on the socket.
    fn record_death(&mut self, raw_json: &str, connection: &str) -> ReplayWorkerDied {
        self.stream = None;
        self.active = false;
        let pid = self.process.as_ref().map(Child::id);
        let process_end = match self.process.take() {
            Some(mut child) => reap_worker(&mut child, WORKER_EXIT_GRACE),
            None => "the session holds no process handle for it".to_string(),
        };
        let death = ReplayWorkerDied {
            name: self.name.clone(),
            index: self.index,
            pid,
            query: replay_query_kind(raw_json),
            exit: format!("{connection}; {process_end}"),
        };
        error!("{death}");
        self.last_death = Some(death.clone());
        death
    }

    /// Close the connection to the worker and stop it. Used when the
    /// connection can no longer be trusted to pair answers with queries.
    fn abandon_connection(&mut self) {
        self.stream = None;
        if let Some(child) = self.process.as_mut() {
            let _ = child.kill();
            let _ = child.wait();
        }
        self.process = None;
        self.active = false;
    }
}

/// Wait up to `grace` for a worker that closed its connection to exit, and
/// describe how it ended: `the process ended with signal: 11 (SIGSEGV) (core
/// dumped)` (std's `ExitStatus` display). A worker still running after `grace`
/// is stopped, since nothing can be paired with its answers any more.
///
/// The grace is measured through [`crate::wall_clock`], not `Instant`: this
/// function is not inside a `#[cfg(unix)]` / `#[cfg(windows)]` item, so it is
/// compiled into the wasm build, where a raw `std::time` read traps
/// (`tests/wall_clock_sweep_test.rs`).
fn reap_worker(child: &mut Child, grace: Duration) -> String {
    let started_ms = crate::wall_clock::monotonic_ms();
    let grace_ms = u64::try_from(grace.as_millis()).unwrap_or(u64::MAX);
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return format!("the process ended with {status}"),
            Ok(None) if crate::wall_clock::monotonic_ms().saturating_sub(started_ms) < grace_ms => {
                thread::sleep(Duration::from_millis(20))
            }
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                return format!(
                    "the process was still running {}s after its connection ended, so it was stopped",
                    grace.as_secs()
                );
            }
            Err(e) => return format!("its exit status could not be read: {e}"),
        }
    }
}

impl Drop for ReplayWorker {
    fn drop(&mut self) {
        self.abandon_connection();
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
            materialization_cache: MaterializationCache::new(),
            materialization_cache_ctfs_path: default_materialization_cache_ctfs_path(&ct_rr_args.rr_trace_folder),
            respawn_after_worker_death: true,
        }
    }

    /// Make the worker's death final for this session: once it died with a
    /// query in flight, every later query fails with that same
    /// [`ReplayWorkerDied`] instead of starting a fresh worker.
    ///
    /// For sessions whose queries only make sense as a sequence from one
    /// replay position, such as a flow walk. A replacement worker starts at
    /// the beginning of the recording, so a walk continued on it would mix a
    /// position it never reached into its answer: before this existed, a flow
    /// whose worker died in `JumpToCall` fell back to `RunToEntry` on a
    /// replacement and returned the first steps of `main` as the flow.
    pub fn without_respawn_after_worker_death(mut self) -> Self {
        self.respawn_after_worker_death = false;
        self
    }

    /// A session for a new worker named `name`, with an index reserved through
    /// [`crate::paths::reserve_worker_index`] so no other worker this process
    /// creates shares its `(name, index)` socket. Production code creates
    /// sessions through this; [`RecreatorReplaySession::new`] with an explicit
    /// index is for callers that own the namespace (tests).
    pub fn with_reserved_index(name: &str, ct_rr_args: RecreatorArgs) -> RecreatorReplaySession {
        Self::new(name, crate::paths::reserve_worker_index(name), ct_rr_args)
    }

    /// The `(name, index)` pair that names this session's worker socket.
    pub fn worker_identity(&self) -> (&str, usize) {
        (&self.name, self.index)
    }

    pub fn ensure_active_stable(&mut self) -> Result<(), Box<dyn Error>> {
        // start stable process if not active, store fields, setup ipc? store in stable
        if !self.stable.active {
            if !self.respawn_after_worker_death
                && let Some(death) = self.stable.last_death()
            {
                return Err(Box::new(death.clone()));
            }
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

    /// Gate a live query through the materialization cache using the production
    /// replay-worker boundary. On a cache miss this sends
    /// `ReplayQuery::MaterializeInterval` to the worker via `ReplayWorker`'s
    /// [`Recreator`] implementation, records the returned writes, and persists
    /// them into the CTFS container when this session was launched from one.
    pub fn ensure_materialized_for_live_query(
        &mut self,
        tick_lo: u64,
        tick_hi: u64,
    ) -> Result<EnsureOutcome, Box<dyn Error>> {
        self.ensure_active_stable()?;
        let outcome = self
            .materialization_cache
            .ensure_interval_materialized(&mut self.stable, tick_lo, tick_hi)?;
        if outcome == EnsureOutcome::CacheMiss {
            self.persist_materialization_cache()?;
        }
        Ok(outcome)
    }

    fn persist_materialization_cache(&mut self) -> Result<(), Box<dyn Error>> {
        let Some(path) = &self.materialization_cache_ctfs_path else {
            return Ok(());
        };
        let backing = Box::new(LocalFileSource::open(path)?);
        let mut overlay = CtfsBlockOverlay::new(backing, OverlayMode::Persist)?;
        self.materialization_cache.persist(&mut overlay)?;
        let mut sink = FileBlockSink::open(path)?;
        self.materialization_cache.flush(&mut overlay, &mut sink)?;
        Ok(())
    }
}

fn default_materialization_cache_ctfs_path(path: &Path) -> Option<PathBuf> {
    if path.extension().and_then(|ext| ext.to_str()) == Some("ct") {
        Some(path.to_path_buf())
    } else {
        None
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
        if let Err(err) = self.stable.dispatch_replay_query(ReplayQuery::DeleteBreakpoints) {
            warn!("failed to clear internal run-to-entry breakpoints: {err}");
        }
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
            &self
                .stable
                .dispatch_replay_query(ReplayQuery::LoadLocals { arg: arg.into() })?,
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

    fn add_breakpoint(
        &mut self,
        path: &str,
        line: i64,
        column: Option<i64>,
        condition: Option<String>,
    ) -> Result<Breakpoint, Box<dyn Error>> {
        self.ensure_active_stable()?;
        // The Nim stable-side `AddBreakpoint` query is currently
        // line-only (M1 only wires the column through the materialised
        // path).  We still record the column on the returned
        // `Breakpoint` so the DAP response surfaces it and the Continue
        // stop check (which lives in the materialised path) sees a
        // consistent record once the stable side is taught about the
        // column in a follow-up.  M9 follows the same pattern for the
        // `condition` field: surfaced on the response, enforced on the
        // materialised path.
        let mut breakpoint =
            serde_json::from_str::<Breakpoint>(&self.stable.dispatch_replay_query(ReplayQuery::AddBreakpoint {
                path: path.to_string(),
                line,
            })?)?;
        breakpoint.column = column;
        breakpoint.condition = condition;
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

    fn worker_death(&self) -> Option<String> {
        self.stable.last_death().map(ToString::to_string)
    }

    fn serves_geid_positions(&self) -> bool {
        true
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
                replayed: true,
            }]);
        }
        Ok(processes)
    }

    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }

    fn omniscient_db(&self) -> Option<&dyn crate::omniscient_db::OmniscientDb> {
        Some(&self.materialization_cache)
    }
}

impl Recreator for RecreatorReplaySession {
    fn re_execute_and_materialize(
        &mut self,
        tick_lo: u64,
        tick_hi: u64,
    ) -> Result<MaterializedInterval, Box<dyn Error>> {
        self.ensure_active_stable()?;
        let response = self
            .stable
            .dispatch_replay_query(ReplayQuery::MaterializeInterval { tick_lo, tick_hi })?;
        materialized_interval_from_worker_response(tick_lo, tick_hi, &response)
    }
}

impl Recreator for ReplayWorker {
    fn re_execute_and_materialize(
        &mut self,
        tick_lo: u64,
        tick_hi: u64,
    ) -> Result<MaterializedInterval, Box<dyn Error>> {
        if !self.active {
            return Err("replay worker is not active".into());
        }
        let response = self.dispatch_replay_query(ReplayQuery::MaterializeInterval { tick_lo, tick_hi })?;
        materialized_interval_from_worker_response(tick_lo, tick_hi, &response)
    }
}

fn materialized_interval_from_worker_response(
    expected_lo: u64,
    expected_hi: u64,
    response: &str,
) -> Result<MaterializedInterval, Box<dyn Error>> {
    let envelope: MaterializeIntervalResponse = serde_json::from_str(response)?;
    if envelope.tick_lo != expected_lo || envelope.tick_hi != expected_hi {
        return Err(format!(
            "MaterializeInterval response interval mismatch: requested [{expected_lo}, {expected_hi}), got [{}, {})",
            envelope.tick_lo, envelope.tick_hi
        )
        .into());
    }
    if envelope.format != "WLOG" {
        return Err(format!("MaterializeInterval unsupported memwrites format '{}'", envelope.format).into());
    }

    let image = BASE64_STANDARD
        .decode(envelope.memwrites_base64.as_bytes())
        .map_err(|e| format!("MaterializeInterval memwrites_base64 decode failed: {e}"))?;
    let writes = decode_memwrites(&image)
        .map_err(|e| format!("MaterializeInterval memwrites.tc decode failed: {e}"))?
        .into_iter()
        .filter(|(_, write)| write.tick >= expected_lo && write.tick < expected_hi)
        .collect();
    let line_hits = match envelope.linehits_base64 {
        Some(linehits_base64) => {
            let image = BASE64_STANDARD
                .decode(linehits_base64.as_bytes())
                .map_err(|e| format!("MaterializeInterval linehits_base64 decode failed: {e}"))?;
            decode_linehits(&image)
                .map_err(|e| format!("MaterializeInterval linehits.tc decode failed: {e}"))?
                .into_iter()
                .flat_map(|(file_id, line, ticks)| {
                    // The LOCATION travels; the cache turns it into an address
                    // in its own space when it ingests it, so nothing outside
                    // that space builds a `linehits.tc` key.
                    ticks
                        .into_iter()
                        .filter(move |tick| *tick >= expected_lo && *tick < expected_hi)
                        .map(move |tick| {
                            (
                                (file_id, line),
                                crate::ctfs_trace_reader::interval_tagged_map::LineHitEntry { tick },
                            )
                        })
                })
                .collect()
        }
        None => Vec::new(),
    };
    Ok(MaterializedInterval { writes, line_hits })
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

    fn memwrite(tick: u64, new_value: u64) -> crate::ctfs_trace_reader::interval_tagged_map::MemWriteEntry {
        crate::ctfs_trace_reader::interval_tagged_map::MemWriteEntry {
            tick,
            pc: 0xCAFE,
            size: 8,
            old_value: 0,
            new_value,
        }
    }

    #[test]
    fn materialize_interval_response_decodes_wlog_and_clips_to_requested_range() {
        let image = crate::ctfs_trace_reader::server_prep_encoding::encode_memwrites(
            &crate::ctfs_trace_reader::server_prep_encoding::CollapsedMemwrites {
                per_address: vec![(
                    0x4000,
                    vec![memwrite(9, 1), memwrite(10, 2), memwrite(19, 3), memwrite(20, 4)],
                )],
            },
        );
        let response = MaterializeIntervalResponse {
            tick_lo: 10,
            tick_hi: 20,
            format: "WLOG".to_string(),
            memwrites_base64: BASE64_STANDARD.encode(image),
            linehits_base64: None,
        };

        let materialized =
            materialized_interval_from_worker_response(10, 20, &serde_json::to_string(&response).unwrap()).unwrap();

        assert_eq!(materialized.writes.len(), 2);
        assert_eq!(materialized.writes[0].0, 0x4000);
        assert_eq!(materialized.writes[0].1, memwrite(10, 2));
        assert_eq!(materialized.writes[1].1, memwrite(19, 3));
    }

    #[test]
    fn test_db_backend_decodes_rr_memwrite_response_exactly() {
        let inside_first = crate::ctfs_trace_reader::interval_tagged_map::MemWriteEntry {
            tick: 200,
            pc: 0x401120,
            size: 8,
            old_value: 0x0102_0304_0506_0708,
            new_value: 0x1122_3344,
        };
        let inside_second = crate::ctfs_trace_reader::interval_tagged_map::MemWriteEntry {
            tick: 201,
            pc: 0x40112B,
            size: 8,
            old_value: 0x1122_3344,
            new_value: 0x1122_3355,
        };
        let before = crate::ctfs_trace_reader::interval_tagged_map::MemWriteEntry {
            tick: 199,
            pc: 0x401110,
            size: 8,
            old_value: 0,
            new_value: 1,
        };
        let after = crate::ctfs_trace_reader::interval_tagged_map::MemWriteEntry {
            tick: 202,
            pc: 0x401133,
            size: 8,
            old_value: 0x1122_3355,
            new_value: 0x1122_3366,
        };
        let image = crate::ctfs_trace_reader::server_prep_encoding::encode_memwrites(
            &crate::ctfs_trace_reader::server_prep_encoding::CollapsedMemwrites {
                per_address: vec![(0x404030, vec![before, inside_first, inside_second, after])],
            },
        );
        let response = MaterializeIntervalResponse {
            tick_lo: 200,
            tick_hi: 202,
            format: "WLOG".to_string(),
            memwrites_base64: BASE64_STANDARD.encode(image),
            linehits_base64: None,
        };

        let materialized =
            materialized_interval_from_worker_response(200, 202, &serde_json::to_string(&response).unwrap()).unwrap();

        assert_eq!(
            materialized.writes,
            vec![(0x404030, inside_first), (0x404030, inside_second)]
        );
        assert!(
            !materialized.writes.is_empty(),
            "RR memwrite response must not be accepted through an empty-success fallback"
        );
    }

    #[test]
    fn materialize_interval_response_decodes_linehits_and_clips_to_requested_range() {
        let memwrites_image = crate::ctfs_trace_reader::server_prep_encoding::encode_memwrites(
            &crate::ctfs_trace_reader::server_prep_encoding::CollapsedMemwrites { per_address: vec![] },
        );
        let linehits_image = crate::ctfs_trace_reader::server_prep_encoding::encode_linehits(
            &crate::ctfs_trace_reader::server_prep_encoding::CollapsedLinehits {
                per_line: vec![(7, 100, vec![9, 10, 19, 20])],
            },
        );
        let response = MaterializeIntervalResponse {
            tick_lo: 10,
            tick_hi: 20,
            format: "WLOG".to_string(),
            memwrites_base64: BASE64_STANDARD.encode(memwrites_image),
            linehits_base64: Some(BASE64_STANDARD.encode(linehits_image)),
        };

        let materialized =
            materialized_interval_from_worker_response(10, 20, &serde_json::to_string(&response).unwrap()).unwrap();

        assert_eq!(
            materialized.line_hits,
            vec![
                (
                    (7, 100),
                    crate::ctfs_trace_reader::interval_tagged_map::LineHitEntry { tick: 10 }
                ),
                (
                    (7, 100),
                    crate::ctfs_trace_reader::interval_tagged_map::LineHitEntry { tick: 19 }
                ),
            ]
        );
    }

    #[test]
    fn test_db_backend_decodes_rr_linehit_response_exactly() {
        let inside_write = crate::ctfs_trace_reader::interval_tagged_map::MemWriteEntry {
            tick: 301,
            pc: 0x40112B,
            size: 8,
            old_value: 0x1122_3344,
            new_value: 0x1122_3355,
        };
        let memwrites_image = crate::ctfs_trace_reader::server_prep_encoding::encode_memwrites(
            &crate::ctfs_trace_reader::server_prep_encoding::CollapsedMemwrites {
                per_address: vec![(0x404030, vec![inside_write])],
            },
        );
        let linehits_image = crate::ctfs_trace_reader::server_prep_encoding::encode_linehits(
            &crate::ctfs_trace_reader::server_prep_encoding::CollapsedLinehits {
                per_line: vec![(11, 71, vec![299, 300]), (11, 72, vec![301, 302])],
            },
        );
        let response = MaterializeIntervalResponse {
            tick_lo: 300,
            tick_hi: 302,
            format: "WLOG".to_string(),
            memwrites_base64: BASE64_STANDARD.encode(memwrites_image),
            linehits_base64: Some(BASE64_STANDARD.encode(linehits_image)),
        };

        let materialized =
            materialized_interval_from_worker_response(300, 302, &serde_json::to_string(&response).unwrap()).unwrap();

        assert_eq!(materialized.writes, vec![(0x404030, inside_write)]);
        assert_eq!(
            materialized.line_hits,
            vec![
                (
                    (11, 71),
                    crate::ctfs_trace_reader::interval_tagged_map::LineHitEntry { tick: 300 },
                ),
                (
                    (11, 72),
                    crate::ctfs_trace_reader::interval_tagged_map::LineHitEntry { tick: 301 },
                ),
            ]
        );
        assert!(
            !materialized.line_hits.is_empty(),
            "RR linehit response must not be accepted through an empty-success fallback"
        );
    }

    #[test]
    fn materialize_interval_response_rejects_interval_mismatch() {
        let image = crate::ctfs_trace_reader::server_prep_encoding::encode_memwrites(
            &crate::ctfs_trace_reader::server_prep_encoding::CollapsedMemwrites { per_address: vec![] },
        );
        let response = MaterializeIntervalResponse {
            tick_lo: 11,
            tick_hi: 20,
            format: "WLOG".to_string(),
            memwrites_base64: BASE64_STANDARD.encode(image),
            linehits_base64: None,
        };

        let err = materialized_interval_from_worker_response(10, 20, &serde_json::to_string(&response).unwrap())
            .unwrap_err()
            .to_string();
        assert!(err.contains("interval mismatch"));
    }

    #[cfg(unix)]
    #[test]
    fn recreator_session_dispatches_materialize_interval_to_worker_boundary() {
        use std::io::{BufRead, Write};
        use std::os::unix::net::UnixStream;

        let image = crate::ctfs_trace_reader::server_prep_encoding::encode_memwrites(
            &crate::ctfs_trace_reader::server_prep_encoding::CollapsedMemwrites {
                per_address: vec![(0x5000, vec![memwrite(12, 99)])],
            },
        );
        let linehits_image = crate::ctfs_trace_reader::server_prep_encoding::encode_linehits(
            &crate::ctfs_trace_reader::server_prep_encoding::CollapsedLinehits {
                per_line: vec![(2, 30, vec![12])],
            },
        );
        let response = MaterializeIntervalResponse {
            tick_lo: 10,
            tick_hi: 20,
            format: "WLOG".to_string(),
            memwrites_base64: BASE64_STANDARD.encode(image),
            linehits_base64: Some(BASE64_STANDARD.encode(linehits_image)),
        };
        let response_json = serde_json::to_string(&response).unwrap();

        let (client, mut server) = UnixStream::pair().unwrap();
        let worker = std::thread::spawn(move || {
            let mut line = String::new();
            {
                let mut reader = std::io::BufReader::new(&mut server);
                reader.read_line(&mut line).unwrap();
            }
            assert_eq!(
                line.trim(),
                r#"{"kind":"MaterializeInterval","tick_lo":10,"tick_hi":20}"#
            );
            server.write_all(format!("{response_json}\n").as_bytes()).unwrap();
        });

        let mut session = RecreatorReplaySession {
            stable: ReplayWorker {
                name: "materialize-test".to_string(),
                index: 0,
                active: true,
                recreator_exe: PathBuf::new(),
                rr_trace_folder: PathBuf::new(),
                live_program: None,
                live_program_args: vec![],
                live_cwd: None,
                live_recording_dir: None,
                run_id: "test-run".to_string(),
                runtime_dir: PathBuf::new(),
                recording_id: "test-recording".to_string(),
                process: None,
                stream: Some(client),
                last_death: None,
            },
            recreator_exe: PathBuf::new(),
            rr_trace_folder: PathBuf::new(),
            name: "materialize-test".to_string(),
            index: 0,
            last_c_location: None,
            materialization_cache: MaterializationCache::new(),
            materialization_cache_ctfs_path: None,
            respawn_after_worker_death: true,
        };

        let materialized = session.re_execute_and_materialize(10, 20).unwrap();
        worker.join().unwrap();

        assert_eq!(materialized.writes, vec![(0x5000, memwrite(12, 99))]);
        assert_eq!(
            materialized.line_hits,
            vec![(
                (2, 30),
                crate::ctfs_trace_reader::interval_tagged_map::LineHitEntry { tick: 12 },
            )]
        );
    }

    #[cfg(unix)]
    #[test]
    fn recreator_session_live_gate_uses_worker_boundary_and_cache() {
        use crate::replay::ReplaySession;
        use std::io::{BufRead, Write};
        use std::os::unix::net::UnixStream;

        let image = crate::ctfs_trace_reader::server_prep_encoding::encode_memwrites(
            &crate::ctfs_trace_reader::server_prep_encoding::CollapsedMemwrites {
                per_address: vec![(0x6000, vec![memwrite(12, 77)])],
            },
        );
        let response = MaterializeIntervalResponse {
            tick_lo: 0,
            tick_hi: 20,
            format: "WLOG".to_string(),
            memwrites_base64: BASE64_STANDARD.encode(image),
            linehits_base64: None,
        };
        let response_json = serde_json::to_string(&response).unwrap();

        let (client, mut server) = UnixStream::pair().unwrap();
        let worker = std::thread::spawn(move || {
            let mut line = String::new();
            {
                let mut reader = std::io::BufReader::new(&mut server);
                reader.read_line(&mut line).unwrap();
            }
            assert_eq!(
                line.trim(),
                r#"{"kind":"MaterializeInterval","tick_lo":0,"tick_hi":20}"#
            );
            server.write_all(format!("{response_json}\n").as_bytes()).unwrap();
        });

        let mut session = RecreatorReplaySession {
            stable: ReplayWorker {
                name: "live-gate-test".to_string(),
                index: 0,
                active: true,
                recreator_exe: PathBuf::new(),
                rr_trace_folder: PathBuf::new(),
                live_program: None,
                live_program_args: vec![],
                live_cwd: None,
                live_recording_dir: None,
                run_id: "test-run".to_string(),
                runtime_dir: PathBuf::new(),
                recording_id: "test-recording".to_string(),
                process: None,
                stream: Some(client),
                last_death: None,
            },
            recreator_exe: PathBuf::new(),
            rr_trace_folder: PathBuf::new(),
            name: "live-gate-test".to_string(),
            index: 0,
            last_c_location: None,
            materialization_cache: MaterializationCache::new(),
            materialization_cache_ctfs_path: None,
            respawn_after_worker_death: true,
        };

        assert_eq!(
            session.ensure_materialized_for_live_query(0, 20).unwrap(),
            EnsureOutcome::CacheMiss
        );
        assert_eq!(
            session.ensure_materialized_for_live_query(0, 20).unwrap(),
            EnsureOutcome::CacheHit,
            "covered interval is served without sending a second worker query"
        );
        worker.join().unwrap();

        let db = session.omniscient_db().expect("session exposes live cache");
        assert!(db.is_present());
        assert_eq!(db.last_write_before(0x6000, 8, 13).unwrap().new_value, 77);
    }

    /// A `ReplayWorker` whose "process" is a real `sh` holding the other end of
    /// a real socket as its stdin: it reads one query line and then runs
    /// `then` (for example `kill -KILL $$`).
    ///
    /// Not a mock of `ct-native-replay`: what these tests exercise is how the
    /// session observes a worker going away — EOF on a real socket and a real
    /// exit status from `waitpid` — and both are the kernel's, whatever the
    /// process was. Making a real `ct-native-replay` die on cue would need a
    /// crashing replay, which is what the end-to-end
    /// `rust_flow_integration` test covers.
    #[cfg(unix)]
    fn worker_that_reads_one_query_then(then: &str, name: &str) -> ReplayWorker {
        use std::os::fd::OwnedFd;
        let (client, server) = UnixStream::pair().unwrap();
        // Bounded, so a regression that stops seeing EOF fails instead of hanging.
        client.set_read_timeout(Some(Duration::from_secs(30))).unwrap();
        let child = Command::new("sh")
            .arg("-c")
            .arg(format!("read -r query; {then}"))
            .stdin(Stdio::from(OwnedFd::from(server)))
            .stdout(Stdio::null())
            .spawn()
            .unwrap();
        let mut worker = ReplayWorker::new(
            name,
            1,
            Path::new("/nonexistent/ct-native-replay"),
            Path::new("/nonexistent/trace"),
        );
        worker.process = Some(child);
        worker.stream = Some(client);
        worker.active = true;
        worker
    }

    #[cfg(unix)]
    fn expect_death<'a>(err: &'a (dyn Error + 'static)) -> &'a ReplayWorkerDied {
        err.downcast_ref::<ReplayWorkerDied>()
            .unwrap_or_else(|| panic!("expected a ReplayWorkerDied, got: {err}"))
    }

    /// A worker that dies with a query in flight is reported as a death that
    /// names it, the query and the signal — not as an anonymous "disconnected",
    /// which is what let a SIGSEGV in the `flow` worker pass for an empty flow.
    #[cfg(unix)]
    #[test]
    fn a_worker_killed_mid_query_is_reported_as_a_death_naming_it_and_the_signal() {
        let mut worker = worker_that_reads_one_query_then("kill -KILL $$", "flow");
        let pid = worker.process.as_ref().unwrap().id();

        let err = worker
            .dispatch_replay_query(ReplayQuery::RunToEntry)
            .expect_err("a worker that dies without answering cannot have answered");
        let death = expect_death(err.as_ref()).clone();

        assert_eq!(death.name, "flow");
        assert_eq!(death.index, 1);
        assert_eq!(death.pid, Some(pid));
        assert_eq!(death.query, "RunToEntry");
        assert!(
            death.exit.contains("SIGKILL"),
            "the exit must name the signal: {}",
            death.exit
        );
        let message = death.to_string();
        assert!(
            message.contains("the `flow` replay worker") && message.contains("died while answering RunToEntry"),
            "got: {message}"
        );
        assert!(!worker.active, "a dead worker must not be reported active");
        assert_eq!(worker.last_death(), Some(&death));
    }

    #[cfg(unix)]
    #[test]
    fn a_worker_that_exits_mid_query_is_reported_with_its_exit_status() {
        let mut worker = worker_that_reads_one_query_then("exit 3", "stable");
        let err = worker
            .dispatch_replay_query(ReplayQuery::LoadLocation)
            .expect_err("a worker that exits without answering cannot have answered");
        let death = expect_death(err.as_ref());
        assert_eq!(death.query, "LoadLocation");
        assert!(
            death.exit.contains("exit status: 3"),
            "the exit must carry the status: {}",
            death.exit
        );
    }

    /// A session built `without_respawn_after_worker_death` answers every
    /// query after the death with that death, instead of starting a fresh
    /// worker at the beginning of the recording. The worker executable here
    /// does not exist, so a respawn attempt would fail with a start error
    /// rather than the death: the assertion distinguishes the two.
    #[cfg(unix)]
    #[test]
    fn a_session_without_respawn_keeps_reporting_its_workers_death() {
        let mut session = RecreatorReplaySession::new(
            "flow",
            1,
            RecreatorArgs {
                worker_exe: PathBuf::from("/nonexistent/ct-native-replay"),
                rr_trace_folder: PathBuf::from("/nonexistent/trace"),
                ..RecreatorArgs::default()
            },
        )
        .without_respawn_after_worker_death();
        session.stable = worker_that_reads_one_query_then("kill -KILL $$", "flow");

        let first = session.run_to_entry().expect_err("the worker died answering it");
        let first = expect_death(first.as_ref()).clone();
        let later = session
            .run_to_entry()
            .expect_err("a dead worker must not be silently replaced");
        assert_eq!(expect_death(later.as_ref()), &first);
        assert_eq!(session.worker_death(), Some(first.to_string()));
    }

    /// The arguments of `command`, as strings.
    #[cfg(unix)]
    fn args_of(command: &Command) -> Vec<String> {
        command.get_args().map(|a| a.to_string_lossy().into_owned()).collect()
    }

    /// Every route `start` spawns names this process as the worker's parent,
    /// so a worker db-backend dies before connecting to does not outlive it
    /// (codetracer-pm issue
    /// `2026-10-22-orphaned-mcr-replay-worker-waits-in-accept-after-its-replay-server-is-gone.md`).
    /// The command is inspected rather than run: what the worker does with
    /// the option is `ct-native-replay`'s and `ct-mcr`'s to test, and both
    /// do, against their real binaries.
    #[cfg(unix)]
    #[test]
    fn every_worker_route_is_started_with_this_process_as_its_parent_pid() {
        let own_pid = std::process::id().to_string();
        let expect_parent_pid = |args: &[String], route: &str| {
            let at = args
                .iter()
                .position(|a| a == "--parent-pid")
                .unwrap_or_else(|| panic!("{route}: no --parent-pid in {args:?}"));
            assert_eq!(args.get(at + 1), Some(&own_pid), "{route}: {args:?}");
        };

        let trace = ReplayWorker::new("stable", 0, Path::new("/x/ct-native-replay"), Path::new("/x/trace.ct"));
        let command = trace.worker_command(None);
        assert_eq!(command.get_program(), "/x/ct-native-replay");
        let args = args_of(&command);
        expect_parent_pid(&args, "trace");
        assert_eq!(args.first().map(String::as_str), Some("replay-worker"));
        assert_eq!(
            args.last().map(String::as_str),
            Some("/x/trace.ct"),
            "the trace stays last"
        );

        let mut live = ReplayWorker::new("stable", 1, Path::new("/x/ct-native-replay"), Path::new(""));
        live.live_program = Some(PathBuf::from("/x/program"));
        let args = args_of(&live.worker_command(None));
        expect_parent_pid(&args, "live");
        assert!(
            args.windows(2).any(|w| w == ["--live-program", "/x/program"]),
            "{args:?}"
        );

        // `ct-mcr replay-worker --coop-query` serves a socket, so it takes
        // `--parent-pid` too.
        let coop = CoopQueryArgs {
            exe: Some(PathBuf::from("/x/ct-mcr")),
            program: Some("/x/program".to_string()),
            func: Some("main".to_string()),
        };
        let command = trace.worker_command(Some(&coop));
        assert_eq!(command.get_program(), "/x/ct-mcr");
        let args = args_of(&command);
        expect_parent_pid(&args, "coop-query");
        assert!(args.iter().any(|a| a == "--coop-query"), "{args:?}");
        assert_eq!(
            args.last().map(String::as_str),
            Some("/x/trace.ct"),
            "the trace stays last"
        );
    }
}
