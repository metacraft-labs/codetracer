use serde_json::json;
// use std::collections::{HashMap, HashSet};
use std::error::Error;
use std::fmt;
#[cfg(all(feature = "io-transport", unix))]
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread;
use std::time::Duration;

use log::{debug, error, info, warn};

use crate::dap::{self, Capabilities, DapMessage, Event, ProtocolMessage, Response};
use crate::dap_types;

use crate::dap_handler::Handler;
use crate::db::Db;
use crate::macro_sourcemap::UpdateExpansionArgs;
#[cfg(not(windows))]
use crate::paths::CODETRACER_PATHS;
use crate::recreator_session::RecreatorArgs;
use crate::task::{
    Action, CallSearchArg, CalltraceLoadArgs, CollapseCallsArgs, CtLoadFlowArguments, CtLoadLocalsArguments,
    FunctionLocation, GoToTicksArguments, LoadHistoryArg, LocalStepJump, Location, ProgramEvent, RunTracepointsArg,
    SourceCallJumpTarget, SourceLocation, StepArg, TraceKind, TracepointId, UpdateTableArgs,
};
use crate::transport_endpoint::DapEndpoint;
#[cfg(not(windows))]
use crate::transport_endpoint::unix_socket_path_for_pid;
#[cfg(windows)]
use crate::transport_endpoint::windows_named_pipe_path_for_pid;

use crate::ctfs_trace_reader::{CTFSTraceReader, ctfs_container::CtfsReader};
use crate::trace_reader::TraceReader;

use crate::transport::DapTransport;

#[cfg(feature = "browser-transport")]
use crate::transport::{DapResult, WorkerTransport};

pub const DAP_SOCKET_NAME: &str = "ct_dap_socket";

// in the future: maybe refactor in a more thread-aware way?
//   or if not: delete

// #[cfg(feature = "io-transport")]
// pub fn make_io_transport() -> Result<(BufReader<std::io::StdinLock<'static>>, std::io::Stdout), Box<dyn Error>> {
//     use std::io::BufReader;

//     let stdin = std::io::stdin();
//     let stdout = std::io::stdout();
//     let reader = BufReader::new(stdin.lock());
//     Ok((reader, stdout))
// }

// #[cfg(feature = "io-transport")]
// pub fn make_socket_transport(
//     socket_path: &PathBuf,
// ) -> Result<(std::io::BufReader<UnixStream>, UnixStream), Box<dyn Error>> {
//     use std::io::BufReader;

//     let stream = UnixStream::connect(socket_path)?;
//     let reader = BufReader::new(stream.try_clone()?);
//     let writer = stream;
//     Ok((reader, writer))
// }

#[cfg(feature = "browser-transport")]
pub fn make_transport() -> DapResult<WorkerTransport> {
    WorkerTransport::new()
}

#[allow(clippy::unwrap_used)] // Mutex poisoning indicates unrecoverable state
#[cfg(unix)]
pub fn socket_path_for(pid: usize) -> PathBuf {
    unix_socket_path_for_pid(
        &CODETRACER_PATHS.lock().unwrap().tmp_path,
        DAP_SOCKET_NAME,
        pid,
        Some("sock"),
    )
}

#[cfg(windows)]
pub fn socket_path_for(pid: usize) -> PathBuf {
    PathBuf::from(windows_named_pipe_path_for_pid(DAP_SOCKET_NAME, pid))
}

#[cfg(not(any(unix, windows)))]
#[allow(clippy::unwrap_used)] // Mutex poisoning indicates unrecoverable state
pub fn socket_path_for(pid: usize) -> PathBuf {
    unix_socket_path_for_pid(
        &CODETRACER_PATHS.lock().unwrap().tmp_path,
        DAP_SOCKET_NAME,
        pid,
        Some("sock"),
    )
}

/// Resolve the `ct-native-replay` binary path from the launch arguments,
/// falling back to environment variable and PATH search when the provided
/// path is empty or absent.
///
/// The fallback chain mirrors the discovery logic used in backend-manager's
/// `ct/open-trace` handler:
///   1. Use the value from the DAP launch `ctRRWorkerExe` argument (if non-empty)
///   2. Check `CODETRACER_CT_NATIVE_REPLAY_CMD` environment variable
///      (falls back to legacy `CODETRACER_CT_RR_SUPPORT_CMD`)
///   3. Search for `ct-native-replay` on `PATH`
///      (falls back to legacy `ct-rr-support`)
///
/// This is necessary because the Nim/Electron frontend's config loader
/// does not auto-discover `ct-native-replay` (the auto-discovery in
/// `common/config.nim` only runs in the native CLI context), so the
/// frontend typically sends an empty `ctRRWorkerExe` in the DAP launch
/// request for RR-based traces.
fn resolve_recreator_exe(from_launch_args: Option<PathBuf>) -> PathBuf {
    // 1. Use the provided path if it's non-empty.
    if let Some(ref path) = from_launch_args {
        if !path.as_os_str().is_empty() {
            info!("ct-native-replay: using path from launch args: {}", path.display());
            return path.clone();
        }
    }

    // 2. Check CODETRACER_CT_NATIVE_REPLAY_CMD environment variable,
    //    falling back to the legacy CODETRACER_CT_RR_SUPPORT_CMD.
    for var_name in &["CODETRACER_CT_NATIVE_REPLAY_CMD", "CODETRACER_CT_RR_SUPPORT_CMD"] {
        if let Ok(env_path) = std::env::var(var_name) {
            if !env_path.is_empty() {
                info!("ct-native-replay: using path from {}: {}", var_name, env_path);
                return PathBuf::from(env_path);
            }
        }
    }

    // 3. Search for ct-native-replay on PATH, falling back to legacy ct-rr-support.
    for exe_name in &["ct-native-replay", "ct-rr-support"] {
        if let Some(path) = find_on_path(exe_name) {
            info!(
                "ct-native-replay: discovered '{}' on PATH: {}",
                exe_name,
                path.display()
            );
            return path;
        }
    }

    warn!(
        "ct-native-replay: not found via launch args, environment, or PATH; \
         RR-based traces will fail to replay"
    );
    PathBuf::new()
}

/// Search for an executable by name in the directories listed in `PATH`.
///
/// Returns the full path to the first matching executable, or `None` if
/// the binary is not found.  This avoids shelling out to `which` which may
/// not be available in all environments.
fn find_on_path(name: &str) -> Option<PathBuf> {
    let path_var = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path_var) {
        let candidate = dir.join(name);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

#[cfg(feature = "io-transport")]
pub fn run_stdio() -> Result<(), Box<dyn Error>> {
    run_with_endpoint(DapEndpoint::Stdio)
}

#[cfg(feature = "io-transport")]
pub fn run(socket_path: &Path) -> Result<(), Box<dyn Error>> {
    #[cfg(windows)]
    {
        // On Windows, the backend-manager passes a TCP address like
        // "127.0.0.1:12345" as the socket path.  Detect this by checking
        // if the path contains a colon followed by digits (host:port format).
        let path_str = socket_path.to_string_lossy();
        if looks_like_tcp_address(&path_str) {
            run_with_endpoint(DapEndpoint::TcpSocket(path_str.into_owned()))
        } else {
            run_with_endpoint(DapEndpoint::WindowsNamedPipe(path_str.into_owned()))
        }
    }

    #[cfg(not(windows))]
    run_with_endpoint(DapEndpoint::UnixSocket(socket_path.to_path_buf()))
}

/// Returns true if the string looks like a TCP address (e.g. "127.0.0.1:12345").
fn looks_like_tcp_address(s: &str) -> bool {
    // A simple heuristic: contains a colon and the part after the last colon
    // is a valid port number.
    if let Some(colon_pos) = s.rfind(':') {
        let port_part = &s[colon_pos + 1..];
        port_part.parse::<u16>().is_ok()
    } else {
        false
    }
}

#[cfg(feature = "io-transport")]
pub fn run_with_endpoint(endpoint: DapEndpoint) -> Result<(), Box<dyn Error>> {
    use std::io::BufReader;

    match endpoint {
        DapEndpoint::Stdio => {
            let stdin = std::io::stdin();
            let stdout = std::io::stdout();
            run_with_stream(BufReader::new(stdin), stdout)
        }
        DapEndpoint::UnixSocket(socket_path) => {
            #[cfg(unix)]
            {
                let stream = UnixStream::connect(&socket_path)?;
                let writer = stream.try_clone()?;
                info!("stream ok out of thread");
                let reader = BufReader::new(stream);
                run_with_stream(reader, writer)
            }
            #[cfg(not(unix))]
            {
                Err(format!(
                    "unix socket transport is not supported on this platform: {}",
                    socket_path.display()
                )
                .into())
            }
        }
        DapEndpoint::WindowsNamedPipe(pipe_path) => {
            #[cfg(windows)]
            {
                let stream = connect_windows_named_pipe(&pipe_path)?;
                let writer = stream.try_clone().map_err(|e| {
                    format!("connected to named pipe '{pipe_path}', but failed to clone stream handle: {e}")
                })?;
                let reader = BufReader::new(stream);
                run_with_stream(reader, writer)
            }

            #[cfg(not(windows))]
            {
                Err(format!("windows named-pipe transport is not supported on this platform: {pipe_path}").into())
            }
        }
        DapEndpoint::TcpSocket(addr) => {
            info!("Connecting to backend-manager via TCP at {addr}");
            let stream = std::net::TcpStream::connect(&addr)
                .map_err(|e| format!("failed to connect to TCP endpoint {addr}: {e}"))?;
            let writer = stream
                .try_clone()
                .map_err(|e| format!("connected to TCP {addr}, but failed to clone stream: {e}"))?;
            let reader = BufReader::new(stream);
            run_with_stream(reader, writer)
        }
    }
}

#[cfg(all(feature = "io-transport", windows))]
fn connect_windows_named_pipe(pipe_path: &str) -> Result<std::fs::File, Box<dyn Error>> {
    use std::ffi::OsStr;
    use std::fs::OpenOptions;
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Foundation::GetLastError;
    use windows_sys::Win32::System::Pipes::WaitNamedPipeW;

    let pipe_path_wide: Vec<u16> = OsStr::new(pipe_path).encode_wide().chain(std::iter::once(0)).collect();

    unsafe {
        // Wait briefly so startup races produce a clear timeout instead of a generic open failure.
        if WaitNamedPipeW(pipe_path_wide.as_ptr(), 5_000) == 0 {
            let err = GetLastError();
            return Err(format!(
                "failed waiting for Windows named pipe '{pipe_path}' (error code {err}); ensure the DAP listener is running and using the same pipe path"
            )
            .into());
        }

        OpenOptions::new().read(true).write(true).open(pipe_path).map_err(|e| {
            let err = GetLastError();
            format!(
                "failed to connect to Windows named pipe '{pipe_path}' after WaitNamedPipeW success (error code {err}): {e}"
            )
            .into()
        })
    }
}

#[cfg(feature = "io-transport")]
pub fn run_with_stream<R, W>(reader: R, writer: W) -> Result<(), Box<dyn Error>>
where
    R: std::io::BufRead + Send + 'static,
    W: std::io::Write + Send + 'static,
{
    let (receiving_sender, receiving_receiver) = mpsc::channel();
    let builder = thread::Builder::new().name("receiving".to_string());
    let receiving_thread = builder.spawn(move || -> Result<(), String> {
        info!("receiving thread");
        let mut reader = reader;

        loop {
            info!("waiting for new DAP message");
            match dap::read_dap_message_from_reader(&mut reader) {
                Ok(msg) => {
                    receiving_sender.send(msg).map_err(|e| {
                        error!("send error: {e:?}");
                        format!("send error: {e:?}")
                    })?;
                }
                Err(e) => {
                    error!("error from read_dap_message_from_reader: {e:?}");
                    break;
                }
            }
        }
        Ok(())
    })?;

    handle_client(receiving_receiver, &receiving_thread, writer)
}

#[allow(clippy::too_many_arguments)]
fn setup(
    trace_folder: &Path,
    trace_file: &Path,
    raw_diff_index: Option<String>,
    recreator_exe: &Path,
    restore_location: Option<Location>,
    sender: Sender<DapMessage>,
    for_launch: bool,
    thread_name: &str,
) -> Result<Handler, Box<dyn Error>> {
    info!("run setup() for {:?}", trace_folder);
    let trace_path = trace_folder.join(trace_file);

    // Materialized traces are CTFS-only. Native MCR traces are also CTFS
    // containers, but they carry recorder streams such as `t00000000000`
    // instead of DB trace files and must fall through to the replay-worker
    // path below.
    //
    // We try several candidate paths because different callers pass trace info
    // differently:
    //   - `trace_folder` itself may be a .ct file (ct-dap-client test runner)
    //   - `trace_path` (trace_folder / trace_file) may be the .ct file
    let ctfs_candidate = if trace_folder.is_file() && is_codetracer_ctfs_file(trace_folder) {
        Some(trace_folder.to_path_buf())
    } else if trace_path.exists() && is_codetracer_ctfs_file(&trace_path) {
        Some(trace_path.clone())
    } else {
        None
    };

    if let Some(ctfs_path) = ctfs_candidate {
        info!("detected CTFS container: {}", ctfs_path.display());
        match CTFSTraceReader::open(&ctfs_path) {
            Ok(ctfs_reader) => {
                info!(
                    "CTFS trace loaded: {} steps, {} calls, {} events",
                    ctfs_reader.step_count(),
                    ctfs_reader.call_count(),
                    ctfs_reader.event_count(),
                );
                let reader: Arc<dyn TraceReader> = Arc::new(ctfs_reader);
                let mut handler = Handler::construct_with_reader(
                    TraceKind::Materialized,
                    RecreatorArgs {
                        name: thread_name.to_string(),
                        ..RecreatorArgs::default()
                    },
                    reader,
                    false,
                );
                handler.raw_diff_index = raw_diff_index;
                // Load macro sourcemaps for Nim macro expansion support (S6).
                handler.load_macro_sourcemaps(trace_folder);
                if for_launch {
                    handler.run_to_entry(dap::Request::default(), restore_location, sender)?;
                }
                handler.initialized = true;
                return Ok(handler);
            }
            Err(e) => {
                // Not a valid CTFS materialised trace — fall through to
                // MCR native replay or rr replay-worker handling below.
                info!(
                    "CTFS open as materialised trace failed for {}: {e} — trying replay-worker path",
                    ctfs_path.display()
                );
            }
        }
    }

    // Legacy `runtime_tracing` materialized layout: a `trace.json` file
    // (a JSON-encoded `Vec<TraceLowLevelEvent>`) instead of a CTFS
    // `.ct` container.  External recorders that have not yet adopted the
    // CTFS writer still emit this — the Noir recorder (`nargo trace`)
    // being the live example.  Treat it exactly like a materialized
    // trace by decoding the events and running the same postprocessing
    // pipeline `CTFSTraceReader::open()` uses, rather than wrongly
    // falling through to the rr/MCR replay-worker path below.
    let legacy_json_path = {
        let direct = trace_folder.join("trace.json");
        if direct.is_file() {
            Some(direct)
        } else if trace_folder.is_file()
            && trace_folder.file_name().map(|n| n == "trace.json").unwrap_or(false)
        {
            Some(trace_folder.to_path_buf())
        } else {
            None
        }
    };
    if let Some(json_path) = legacy_json_path {
        info!(
            "detected legacy runtime_tracing materialized trace: {}",
            json_path.display()
        );
        let json_bytes = std::fs::read(&json_path)?;
        let events: Vec<codetracer_trace_types::TraceLowLevelEvent> =
            serde_json::from_slice(&json_bytes).map_err(|e| {
                format!(
                    "failed to parse legacy trace.json at {}: {e}",
                    json_path.display()
                )
            })?;
        // Workdir: prefer `trace_metadata.json` next to `trace.json`,
        // else fall back to the trace folder itself.
        let meta_workdir = json_path
            .parent()
            .map(|d| d.join("trace_metadata.json"))
            .filter(|p| p.is_file())
            .and_then(|p| std::fs::read(&p).ok())
            .and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok())
            .and_then(|v| {
                v.get("workdir")
                    .and_then(|w| w.as_str())
                    .map(|s| PathBuf::from(s))
            });
        let workdir = meta_workdir.unwrap_or_else(|| {
            json_path
                .parent()
                .map(|d| d.to_path_buf())
                .unwrap_or_else(|| PathBuf::from("."))
        });
        let reader = CTFSTraceReader::from_events(events, &workdir)?;
        info!(
            "legacy materialized trace loaded: {} steps, {} calls, {} events",
            reader.step_count(),
            reader.call_count(),
            reader.event_count(),
        );
        let reader: Arc<dyn TraceReader> = Arc::new(reader);
        let mut handler = Handler::construct_with_reader(
            TraceKind::Materialized,
            RecreatorArgs {
                name: thread_name.to_string(),
                ..RecreatorArgs::default()
            },
            reader,
            false,
        );
        handler.raw_diff_index = raw_diff_index;
        handler.load_macro_sourcemaps(trace_folder);
        if for_launch {
            handler.run_to_entry(dap::Request::default(), restore_location, sender)?;
        }
        handler.initialized = true;
        return Ok(handler);
    }

    info!("not a CTFS materialized trace; trying replay-worker (MCR / rr / TTD .run) path");
    eprintln!("[db-backend setup] trying rr trace path");
    if let Some(path) = resolve_replay_trace_path(trace_folder, trace_file) {
        let db = Db::new(&PathBuf::from(""));
        let ct_rr_args = RecreatorArgs {
            worker_exe: PathBuf::from(recreator_exe),
            rr_trace_folder: path,
            name: thread_name.to_string(),
            // M-REC-11: recording_id plumbing is incremental.  The
            // setup path here does not yet read meta.dat to obtain the
            // UUIDv7; passing an empty string keeps the legacy
            // PID-derived run-id rendezvous for now.  Tracked as part
            // of M-REC-11 follow-up cleanup.
            recording_id: String::new(),
        };
        info!("ct_rr_args {:?}", ct_rr_args);
        let mut handler = Handler::new(TraceKind::Recreator, ct_rr_args, Box::new(db));
        handler.raw_diff_index = raw_diff_index;
        // Load macro sourcemaps for Nim macro expansion support (S6).
        handler.load_macro_sourcemaps(trace_folder);
        if for_launch {
            eprintln!("[db-backend setup] calling run_to_entry");
            handler.run_to_entry(dap::Request::default(), restore_location, sender)?;
            eprintln!("[db-backend setup] run_to_entry completed");
        }
        handler.initialized = true;
        Ok(handler)
    } else {
        Err("problem with reading metadata or trace files and no replay-worker trace path was found".into())
    }
}

/// Browser/WASM-specific setup path that reads trace data from the in-memory
/// VFS instead of the real filesystem.
///
/// In the browser WASM build, the `.ct` CTFS container is pushed into the VFS
/// via `vfs_write_file` from JavaScript before any DAP messages arrive. CTFS
/// is the only supported materialized-trace format — legacy
/// `trace_metadata.json` + `trace.bin` / `trace.json` sidecar layouts are no
/// longer accepted.
///
/// MCR (live recording) traces are detected here via the `meta.dat`
/// `FlagHasMcrFields` bit and rejected with a loud, actionable error.
/// They require an MCR-aware replay engine: the native `setup` path
/// forwards them to the `ct-native-replay` subprocess, but the WASM
/// browser-replay client cannot fork and the in-process emulator is not
/// yet wired into this build (tracked separately under
/// `Browser-Replay.status.org §F5a`). Returning an explicit error here
/// is preferable to letting `CTFSTraceReader::from_bytes` succeed with
/// zero materialised events, which would surface to users as a silent
/// "empty trace" regression.
#[cfg(feature = "browser-transport")]
pub fn setup_from_vfs(
    trace_folder: &str,
    trace_file: &str,
    raw_diff_index: Option<String>,
    restore_location: Option<Location>,
    sender: Sender<DapMessage>,
    for_launch: bool,
    thread_name: &str,
) -> Result<Handler, Box<dyn Error>> {
    info!("setup_from_vfs: folder={trace_folder:?}, file={trace_file:?}");

    // Resolve the effective trace file path within the VFS.
    // The VFS uses forward-slash virtual paths (no OS path separators).
    let join_vfs = |folder: &str, file: &str| -> String {
        if folder.is_empty() {
            file.to_string()
        } else {
            format!("{}/{}", folder.trim_end_matches('/'), file)
        }
    };

    let trace_vfs_path = join_vfs(trace_folder, trace_file);

    // Try every candidate VFS path that could contain the .ct payload:
    //   - `trace_folder` itself when JS pushes the container under the
    //     folder name (e.g. "recording.ct").
    //   - `trace_folder/trace_file` when both are passed.
    let ctfs_candidates = [trace_folder.to_string(), trace_vfs_path];
    for candidate in &ctfs_candidates {
        if !crate::vfs::vfs_exists(candidate) {
            continue;
        }
        let bytes = match crate::vfs::vfs_read(candidate) {
            Some(b) => b,
            None => continue,
        };
        // Check CTFS magic: [C0 DE 72 AC E2]
        if bytes.len() >= 5 && bytes[..5] == [0xC0, 0xDE, 0x72, 0xAC, 0xE2] {
            info!("setup_from_vfs: detected CTFS container at VFS path {candidate:?}");

            // Probe the CTFS container for an MCR live-recording trace.
            // MCR traces declare `FlagHasMcrFields` in `meta.dat` and do
            // NOT ship a materialised events/steps DB — instead they
            // carry per-thread checkpoint streams the in-process Nim
            // emulator can replay. We route those through
            // `EmulatorReplaySession` (F5c-1/2/3); only materialised
            // (non-MCR) traces fall through to the DB-backed
            // `CTFSTraceReader::from_bytes` code path below.
            //
            // Cost note: parsing the meta.dat header is O(meta.dat size)
            // — a few hundred bytes for typical traces — so this adds
            // negligible startup overhead for the materialised-DB code
            // path that flows through immediately afterwards.
            match CtfsReader::from_bytes(bytes.clone()) {
                Ok(mut probe) => {
                    if is_mcr_ctfs_container(&mut probe) {
                        info!("setup_from_vfs: MCR-bearing CTFS at {candidate:?} — routing to EmulatorReplaySession");
                        let emulator =
                            crate::emulator_session::EmulatorReplaySession::new_from_ctfs_bytes(bytes.clone())?;
                        // The emulator owns its own state machine; the
                        // Handler's `reader` field is only consulted by
                        // code paths that key off
                        // `TraceKind::Materialized`, so an empty
                        // `InMemoryTraceReader` is a safe placeholder.
                        let placeholder_reader: Arc<dyn TraceReader> =
                            Arc::new(crate::in_memory_trace_reader::InMemoryTraceReader::new(
                                crate::db::Db::new(&PathBuf::from("")),
                            ));
                        let mut handler = Handler::construct_with_replay(
                            TraceKind::Emulator,
                            RecreatorArgs {
                                name: thread_name.to_string(),
                                ..RecreatorArgs::default()
                            },
                            placeholder_reader,
                            Box::new(emulator),
                            false,
                        );
                        handler.raw_diff_index = raw_diff_index;
                        if for_launch {
                            handler.run_to_entry(dap::Request::default(), restore_location, sender)?;
                        }
                        handler.initialized = true;
                        return Ok(handler);
                    }
                }
                Err(e) => {
                    info!(
                        "setup_from_vfs: CTFS probe failed for {candidate:?}: {e} \
                         — passing through to CTFSTraceReader for a typed error"
                    );
                }
            }

            match CTFSTraceReader::from_bytes(bytes) {
                Ok(ctfs_reader) => {
                    info!(
                        "CTFS trace loaded from VFS: {} steps, {} calls, {} events",
                        ctfs_reader.step_count(),
                        ctfs_reader.call_count(),
                        ctfs_reader.event_count(),
                    );
                    let reader: Arc<dyn TraceReader> = Arc::new(ctfs_reader);
                    let mut handler = Handler::construct_with_reader(
                        TraceKind::Materialized,
                        RecreatorArgs {
                            name: thread_name.to_string(),
                            ..RecreatorArgs::default()
                        },
                        reader,
                        false,
                    );
                    handler.raw_diff_index = raw_diff_index;
                    if for_launch {
                        handler.run_to_entry(dap::Request::default(), restore_location, sender)?;
                    }
                    handler.initialized = true;
                    return Ok(handler);
                }
                Err(e) => {
                    info!("CTFS from_bytes failed for VFS path {candidate:?}: {e}");
                    return Err(format!("CTFS from_bytes failed for {candidate:?}: {e}").into());
                }
            }
        }
    }

    // Legacy `runtime_tracing` materialized layout: a `trace.json` file
    // (a JSON-encoded `Vec<TraceLowLevelEvent>`) instead of a CTFS `.ct`
    // container.  External recorders that have not adopted the CTFS
    // writer still emit this — the Noir recorder (`nargo trace`) is the
    // live example.  The native `try_open_trace` path already handles
    // this format; the browser path must too, otherwise client-side WASM
    // replay of a Noir trace fails after `configurationDone` (the handler
    // is never constructed, so `threads`/`stackTrace` return nothing).
    let json_candidates = [
        join_vfs(trace_folder, "trace.json"),
        trace_folder.to_string(),
    ];
    for candidate in &json_candidates {
        if !crate::vfs::vfs_exists(candidate) || !candidate.ends_with("trace.json") {
            continue;
        }
        let json_bytes = match crate::vfs::vfs_read(candidate) {
            Some(b) => b,
            None => continue,
        };
        info!("setup_from_vfs: detected legacy materialized trace.json at VFS path {candidate:?}");
        let events: Vec<codetracer_trace_types::TraceLowLevelEvent> =
            serde_json::from_slice(&json_bytes).map_err(|e| {
                format!("failed to parse legacy trace.json at {candidate:?}: {e}")
            })?;
        // Workdir: prefer `trace_metadata.json` alongside `trace.json` in
        // the VFS, else fall back to the trace folder.
        let meta_vfs = join_vfs(trace_folder, "trace_metadata.json");
        let workdir = crate::vfs::vfs_read(&meta_vfs)
            .and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok())
            .and_then(|v| {
                v.get("workdir")
                    .and_then(|w| w.as_str())
                    .map(PathBuf::from)
            })
            .unwrap_or_else(|| PathBuf::from(trace_folder));
        let ctfs_reader = CTFSTraceReader::from_events(events, &workdir)?;
        info!(
            "setup_from_vfs: legacy materialized trace loaded: {} steps, {} calls, {} events",
            ctfs_reader.step_count(),
            ctfs_reader.call_count(),
            ctfs_reader.event_count(),
        );
        let reader: Arc<dyn TraceReader> = Arc::new(ctfs_reader);
        let mut handler = Handler::construct_with_reader(
            TraceKind::Materialized,
            RecreatorArgs {
                name: thread_name.to_string(),
                ..RecreatorArgs::default()
            },
            reader,
            false,
        );
        handler.raw_diff_index = raw_diff_index;
        if for_launch {
            handler.run_to_entry(dap::Request::default(), restore_location, sender)?;
        }
        handler.initialized = true;
        return Ok(handler);
    }

    Err("setup_from_vfs: no CTFS (.ct) container or legacy trace.json \
         found in VFS"
        .into())
}

fn resolve_replay_trace_path(trace_folder: &Path, trace_file: &Path) -> Option<PathBuf> {
    // MCR traces: if trace_folder itself is a .ct file, use it directly.
    // The ct-dap-client test runner passes the .ct file path as trace_folder
    // for MCR traces. ct-native-replay detects .ct files and routes them to
    // the MCR debugserver.
    if trace_folder.is_file()
        && trace_folder
            .extension()
            .is_some_and(|ext| ext == std::ffi::OsStr::new("ct"))
    {
        return Some(trace_folder.to_path_buf());
    }

    // Legacy rr trace: a directory `rr/` inside the trace folder means this
    // was produced by `ct-native-replay record` (no --backend mcr). Since
    // M-REC-1.5/M-REC-11 the recorder now drops a CTFS metadata sidecar
    // (`trace.ct`) into the same folder; that file carries only the recording
    // manifest, NOT the recorder streams the MCR debugserver expects.  If we
    // routed such a folder through the `.ct` branch below, ct-native-replay
    // would treat the sidecar as an MCR container, spawn the MCR debugserver,
    // and immediately fail with `ct-mcr binary not found`. We therefore check
    // for the rr subdirectory first and prefer it whenever it exists — MCR
    // recordings never produce a sibling `rr/` directory, so this disambiguates
    // safely without affecting genuine MCR traces.
    let legacy_rr_path = trace_folder.join("rr");
    if legacy_rr_path.is_dir() {
        return Some(legacy_rr_path);
    }

    let explicit_trace_path = trace_folder.join(trace_file);

    // MCR traces in a directory: check if trace_file resolves to a .ct file
    if explicit_trace_path
        .extension()
        .is_some_and(|ext| ext == std::ffi::OsStr::new("ct"))
        && explicit_trace_path.exists()
    {
        return Some(explicit_trace_path);
    }

    if explicit_trace_path
        .extension()
        .is_some_and(|ext| ext == std::ffi::OsStr::new("run"))
        && explicit_trace_path.exists()
    {
        return Some(explicit_trace_path);
    }

    // Windows TTD recordings produced via `ct record` may not pass an explicit
    // `trace_file` launch argument. In that case, discover a `.run` file in the
    // trace folder and route replay through the worker path.
    if let Ok(entries) = std::fs::read_dir(trace_folder) {
        let mut newest_run: Option<(std::time::SystemTime, PathBuf)> = None;
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().is_none_or(|ext| ext != std::ffi::OsStr::new("run")) {
                continue;
            }
            let modified = entry
                .metadata()
                .ok()
                .and_then(|meta| meta.modified().ok())
                .unwrap_or(std::time::SystemTime::UNIX_EPOCH);
            if newest_run.as_ref().is_none_or(|(current, _)| modified > *current) {
                newest_run = Some((modified, path));
            }
        }
        if let Some((_, path)) = newest_run {
            return Some(path);
        }
    }

    if legacy_rr_path.exists() {
        Some(legacy_rr_path)
    } else {
        None
    }
}

/// Check whether `path` is a CTFS binary container by reading the first
/// 5 bytes and comparing against the CTFS magic: `[C0 DE 72 AC E2]`.
///
/// Returns `false` for non-existent files, files smaller than 5 bytes,
/// or any I/O error.  This is intentionally a quick check (no full parse)
/// so it can be used as a cheap format-detection gate before attempting
/// the more expensive `CTFSTraceReader::open`.
/// Find the first `.ct` file in a directory, if any.
///
/// The shell recorder (and potentially other recorders using the Nim CTFS
/// writer) names the `.ct` file after the recorded program rather than using
/// a fixed name like `trace.ct`. This helper scans the directory for any file
/// with a `.ct` extension so the auto-detect logic can find it regardless of
/// the naming convention used by the recorder.
fn find_ct_file_in_dir(dir: &Path) -> Option<PathBuf> {
    let entries = std::fs::read_dir(dir).ok()?;
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().is_some_and(|ext| ext == "ct") && path.is_file() {
            return Some(path);
        }
    }
    None
}

/// Determine whether the trace in `folder` is a DB-based trace (JavaScript,
/// Python, Ruby, etc.) that does NOT require an rr replay worker.
///
/// Materialized traces are CTFS-only, so this reduces to detecting whether
/// the folder (or the resolved trace file) is a CodeTracer DB CTFS
/// container with materialized contents (`steps.dat` or `events.log`).
/// Native MCR traces also use CTFS magic but their stream layout is handled
/// by ct-native-replay; `is_codetracer_ctfs_file` distinguishes the two by
/// looking for the DB stream files inside the container.
///
/// This check prevents `resolve_recreator_exe` from auto-discovering
/// `ct-native-replay` on PATH for DB traces, which would cause the rr replay
/// worker to start and fail.
fn is_db_trace(folder: &Path, trace_file: &Path) -> bool {
    if folder.is_file() && is_codetracer_ctfs_file(folder) {
        return true;
    }
    let trace_path = folder.join(trace_file);
    if trace_path.exists() && is_codetracer_ctfs_file(&trace_path) {
        return true;
    }
    false
}

fn is_codetracer_ctfs_file(path: &Path) -> bool {
    let Ok(reader) = CtfsReader::open(path) else {
        return false;
    };
    reader.has_file("steps.dat") || reader.has_file("events.log")
}

/// Returns true if the CTFS container contains a `meta.dat` declaring
/// MCR fields (`FlagHasMcrFields = 0x1`). Such traces require the
/// MCR-native replay engine and cannot be served by the materialized
/// DB-trace reader.
///
/// The native `dap_server::setup` path falls back to the
/// `ct-native-replay` subprocess for MCR traces. The WASM
/// `setup_from_vfs` path errors loudly because browsers cannot fork and
/// the in-process emulator is not yet wired into this build (see
/// `Browser-Replay.status.org §F5a`).
///
/// This helper is intentionally tolerant of containers without a
/// `meta.dat` (legacy materialised traces): a missing or unparseable
/// `meta.dat` is treated as "not classifiable as MCR" rather than an
/// error so the caller can fall through to its normal open path.
fn is_mcr_ctfs_container(ctfs: &mut CtfsReader) -> bool {
    let bytes = match ctfs.read_file("meta.dat") {
        Ok(b) => b,
        Err(_) => return false,
    };
    match crate::ctfs_trace_reader::meta_dat::parse_meta_dat(&bytes) {
        Ok(meta) => meta.mcr.is_some(),
        Err(_) => false,
    }
}

fn patch_message_seq(message: &DapMessage, seq: i64) -> DapMessage {
    match message {
        DapMessage::Request(r) => {
            let mut r_with_seq = r.clone();
            r_with_seq.base.seq = seq;
            DapMessage::Request(r_with_seq)
        }
        DapMessage::Response(r) => {
            let mut r_with_seq = r.clone();
            r_with_seq.base.seq = seq;
            DapMessage::Response(r_with_seq)
        }
        DapMessage::Event(e) => {
            let mut e_with_seq = e.clone();
            e_with_seq.base.seq = seq;
            DapMessage::Event(e_with_seq)
        }
    }
}

#[derive(Debug, Clone)]
struct CtDapError {
    message: String,
}

impl CtDapError {
    pub fn new(message: &str) -> Self {
        CtDapError {
            message: message.to_string(),
        }
    }
}

impl fmt::Display for CtDapError {
    fn fmt(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
        write!(formatter, "Ct dap error: {}", self.message)
    }
}

type IsReverseAction = bool;

fn dap_command_to_step_action(command: &str) -> Result<(Action, IsReverseAction), CtDapError> {
    match command {
        "stepIn" => Ok((Action::StepIn, false)),
        "stepOut" => Ok((Action::StepOut, false)),
        "next" => Ok((Action::Next, false)),
        "continue" => Ok((Action::Continue, false)),
        "stepBack" => Ok((Action::Next, true)),
        "reverseContinue" => Ok((Action::Continue, true)),
        // custom for codetracer
        "ct/reverseStepIn" => Ok((Action::StepIn, true)),
        "ct/reverseStepOut" => Ok((Action::StepOut, true)),
        _ => Err(CtDapError::new(&format!("not a recognized dap step action: {command}"))),
    }
}

fn handle_request(handler: &mut Handler, req: dap::Request, sender: Sender<DapMessage>) -> Result<(), Box<dyn Error>> {
    match req.command.as_str() {
        "scopes" => handler.scopes(
            req.clone(),
            req.load_args::<dap_types::ScopesArguments>()?,
            sender.clone(),
        )?,
        "threads" => handler.threads(req.clone(), sender.clone())?,
        "stackTrace" => handler.stack_trace(
            req.clone(),
            req.load_args::<dap_types::StackTraceArguments>()?,
            sender.clone(),
        )?,
        "variables" => handler.variables(
            req.clone(),
            req.load_args::<dap_types::VariablesArguments>()?,
            sender.clone(),
        )?,
        "restart" => handler.run_to_entry(req.clone(), None, sender.clone())?,
        "setBreakpoints" => handler.set_breakpoints(
            req.clone(),
            req.load_args::<dap_types::SetBreakpointsArguments>()?,
            sender.clone(),
        )?,
        "ct/load-locals" => {
            handler.load_locals(req.clone(), req.load_args::<CtLoadLocalsArguments>()?, sender.clone())?
        }
        "ct/update-table" => handler.update_table(req.clone(), req.load_args::<UpdateTableArgs>()?, sender.clone())?,
        "ct/event-load" => handler.event_load(req.clone(), sender.clone())?,
        "ct/load-terminal" => handler.load_terminal(req.clone(), sender.clone())?,
        "ct/collapse-calls" => handler.collapse_calls(req.clone(), req.load_args::<CollapseCallsArgs>()?)?,
        "ct/expand-calls" => handler.expand_calls(req.clone(), req.load_args::<CollapseCallsArgs>()?)?,
        "ct/calltrace-jump" => handler.calltrace_jump(req.clone(), req.load_args::<Location>()?, sender.clone())?,
        "ct/event-jump" => handler.event_jump(req.clone(), req.load_args::<ProgramEvent>()?, sender.clone())?,
        "ct/load-history" => handler.load_history(req.clone(), req.load_args::<LoadHistoryArg>()?, sender.clone())?,
        "ct/history-jump" => handler.history_jump(req.clone(), req.load_args::<Location>()?, sender.clone())?,
        "ct/search-calltrace" => {
            handler.calltrace_search(req.clone(), req.load_args::<CallSearchArg>()?, sender.clone())?
        }
        "ct/source-line-jump" => {
            handler.source_line_jump(req.clone(), req.load_args::<SourceLocation>()?, sender.clone())?
        }
        "ct/source-call-jump" => {
            handler.source_call_jump(req.clone(), req.load_args::<SourceCallJumpTarget>()?, sender.clone())?
        }
        "ct/goto-ticks" => handler.goto_ticks(req.clone(), req.load_args::<GoToTicksArguments>()?, sender.clone())?,
        "ct/local-step-jump" => {
            handler.local_step_jump(req.clone(), req.load_args::<LocalStepJump>()?, sender.clone())?
        }
        "ct/tracepoint-toggle" => {
            handler.tracepoint_toggle(req.clone(), req.load_args::<TracepointId>()?, sender.clone())?
        }
        "ct/tracepoint-delete" => {
            handler.tracepoint_delete(req.clone(), req.load_args::<TracepointId>()?, sender.clone())?
        }
        "ct/trace-jump" => handler.trace_jump(req.clone(), req.load_args::<ProgramEvent>()?, sender.clone())?,
        "ct/load-flow" => handler.load_flow(req.clone(), req.load_args::<CtLoadFlowArguments>()?, sender.clone())?,
        "ct/run-to-entry" => handler.run_to_entry(req.clone(), None, sender.clone())?,
        "ct/run-tracepoints" => {
            handler.run_tracepoints(req.clone(), req.load_args::<RunTracepointsArg>()?, sender.clone())?
        }
        "ct/setup-trace-session" => {
            handler.setup_trace_session(req.clone(), req.load_args::<RunTracepointsArg>()?, sender.clone())?
        }
        "ct/load-calltrace-section" => {
            // TODO: log this when logging logic is properly abstracted
            // info!("load_calltrace_section");

            // it's ok for this to fail with serialization null errors for example
            //   when there are `null` fields in `location`. this can happen when
            //   there is no high level file open/debuginfo for the current location
            //   in this case, the code calling `handle_request` should handle the error
            //   and usually for the client to just not receive a new callstack/calltrace
            //   (maybe to receive a clear error in the future?)
            handler.load_calltrace_section(req.clone(), req.load_args::<CalltraceLoadArgs>()?, sender.clone())?
        }
        "ct/load-asm-function" => {
            handler.load_asm_function(req.clone(), req.load_args::<FunctionLocation>()?, sender.clone())?
        }
        "ct/update-expansion" => {
            handler.update_expansion(req.clone(), req.load_args::<UpdateExpansionArgs>()?, sender.clone())?
        }
        _ => {
            match dap_command_to_step_action(&req.command) {
                Ok((action, is_reverse)) => {
                    // for now ignoring arguments: they contain threadId, but
                    // we assume we have a single thread here for now
                    // we also don't use the other args currently
                    handler.step(req, StepArg::new(action, is_reverse), sender.clone())?;
                }
                Err(_e) => {
                    // TODO: eventually support? or if this is the last  branch
                    // in the top `match`
                    // assume all request left here are unsupported
                    // error!("unsupported dap command: {}", req.command);
                    return Err(format!("command {} not supported here", req.command).into());
                }
            }
        }
    }
    Ok(())
    // write_dap_messages_from_thread(sender, handler, seq)
}

#[derive(Debug, Clone)]
pub struct Ctx {
    pub seq: i64,
    // pub handler: Option<Handler>,
    // pub received_launch: bool,
    pub launch_request: Option<dap::Request>,
    pub launch_trace_folder: PathBuf,
    pub launch_trace_file: PathBuf,
    pub launch_raw_diff_index: Option<String>,
    pub recreator_exe: PathBuf,
    pub restore_location: Option<Location>,
    pub received_configuration_done: bool,

    pub to_stable_sender: Option<Sender<dap::Request>>,
    pub to_flow_sender: Option<Sender<dap::Request>>,
    pub to_tracepoint_sender: Option<Sender<dap::Request>>,
    pub disconnect_response_written: Arc<AtomicBool>,
    pub should_terminate: bool,
}

impl Default for Ctx {
    fn default() -> Self {
        Self {
            seq: 1i64,
            // handler: None,
            // received_launch: false,
            launch_request: None,
            launch_trace_folder: PathBuf::from(""),
            launch_trace_file: PathBuf::from(""),
            launch_raw_diff_index: None,
            recreator_exe: PathBuf::from(""),
            restore_location: None,
            received_configuration_done: false,

            to_stable_sender: None,
            to_flow_sender: None,
            to_tracepoint_sender: None,
            disconnect_response_written: Arc::new(AtomicBool::new(false)),
            should_terminate: false,
        }
    }
}

impl Ctx {
    fn write_dap_messages(
        // <T: DapTransport>(
        &mut self,
        sender: Sender<DapMessage>, // transport: &mut T,
        messages: &[DapMessage],
    ) -> Result<(), Box<dyn Error>> {
        for message in messages {
            let message_with_seq = patch_message_seq(message, self.seq);
            self.seq += 1;
            sender.send(message_with_seq)?;
        }
        Ok(())
    }
}

pub fn handle_message(msg: &DapMessage, sender: Sender<DapMessage>, ctx: &mut Ctx) -> Result<(), Box<dyn Error>> {
    debug!("Handling message: {:?}", msg);

    if let DapMessage::Request(req) = msg {
        info!("handle request {}", req.command);
    } else {
        warn!(
            "handle other kind of message: unexpected; expected a request, but handles: {:?}",
            msg
        );
    }

    match msg {
        DapMessage::Request(req) if req.command == "initialize" => {
            let capabilities = Capabilities {
                supports_loaded_sources_request: Some(false),
                supports_step_back: Some(true),
                supports_configuration_done_request: Some(true),
                supports_disassemble_request: Some(true),
                supports_log_points: Some(true),
                supports_restart_request: Some(true),
            };
            let resp = DapMessage::Response(Response {
                base: ProtocolMessage {
                    seq: ctx.seq,
                    type_: "response".to_string(),
                },
                request_seq: req.base.seq,
                success: true,
                command: "initialize".to_string(),
                message: None,
                body: serde_json::to_value(capabilities)?,
            });
            ctx.write_dap_messages(sender.clone(), &[resp])?;

            let event = DapMessage::Event(Event {
                base: ProtocolMessage {
                    seq: ctx.seq,
                    type_: "event".to_string(),
                },
                event: "initialized".to_string(),
                body: json!({}),
            });
            ctx.write_dap_messages(sender, &[event])?;
        }
        DapMessage::Request(req) if req.command == "launch" => {
            // ctx.received_launch = true;
            ctx.launch_request = Some(req.clone());
            let args = req.load_args::<dap::LaunchRequestArguments>()?;
            if let Some(folder) = &args.trace_folder {
                ctx.launch_trace_folder = folder.clone();
                if let Some(trace_file) = &args.trace_file {
                    ctx.launch_trace_file = trace_file.clone();
                } else {
                    // Auto-detect the trace file. Materialized traces are
                    // CTFS-only (`<program>.ct` or `trace.ct`); legacy
                    // sidecars (`trace.bin` / `trace.json` +
                    // `trace_metadata.json`) are no longer supported.
                    if let Some(ct_path) = find_ct_file_in_dir(folder) {
                        // Store just the file name — setup() joins it with
                        // the folder.
                        if let Some(name) = ct_path.file_name() {
                            ctx.launch_trace_file = name.into();
                        }
                    } else {
                        // No .ct found; default to "trace.ct" so the error
                        // message in setup() points at the canonical name.
                        ctx.launch_trace_file = "trace.ct".into();
                    }
                }

                // TODO: log this when logging logic is properly abstracted
                //info!("stored launch trace folder: {0:?}", ctx.launch_trace_folder)

                ctx.launch_raw_diff_index = args.raw_diff_index.clone();

                // Only resolve the replay-worker executable for non-DB traces.
                // DB-based traces (JavaScript, Python, Ruby, etc.) never use
                // the rr replay worker; auto-discovering ct-native-replay on
                // PATH for these traces would cause a spurious worker start
                // that fails and blocks trace loading.
                ctx.recreator_exe = if is_db_trace(&ctx.launch_trace_folder, &ctx.launch_trace_file) {
                    info!("DB-based trace detected — skipping replay-worker resolution");
                    PathBuf::new()
                } else {
                    resolve_recreator_exe(args.recreator_exe)
                };
                ctx.restore_location = args.restore_location.clone();

                if ctx.received_configuration_done {
                    if let Some(to_stable_sender) = ctx.to_stable_sender.clone() {
                        to_stable_sender.send(req.clone())?;
                    }
                }
            }
            info!(
                "received launch; configuration done? {0:?}; req: {1:?}",
                ctx.received_configuration_done, req
            );

            let resp = DapMessage::Response(Response {
                base: ProtocolMessage {
                    seq: ctx.seq,
                    type_: "response".to_string(),
                },
                request_seq: req.base.seq,
                success: true,
                command: "launch".to_string(),
                message: None,
                body: json!({}),
            });
            ctx.seq += 1;
            sender.send(resp)?;
        }
        DapMessage::Request(req) if req.command == "configurationDone" => {
            // TODO: run to entry/continue here, after setting the `launch` field
            ctx.received_configuration_done = true;
            let resp = DapMessage::Response(Response {
                base: ProtocolMessage {
                    seq: ctx.seq,
                    type_: "response".to_string(),
                },
                request_seq: req.base.seq,
                success: true,
                command: "configurationDone".to_string(),
                message: None,
                body: json!({}),
            });
            ctx.seq += 1;
            sender.send(resp)?;

            // TODO: log this when logging logic is properly abstracted
            info!(
                "configuration done sent response; launch_request: {:?}",
                ctx.launch_request,
            );
            if let Some(launch_request) = ctx.launch_request.clone() {
                if let Some(to_stable_sender) = ctx.to_stable_sender.clone() {
                    to_stable_sender.send(launch_request)?;
                }
            }
        }
        DapMessage::Request(req) if req.command == "disconnect" => {
            // let args: dap_types::DisconnectArguments = req.load_args()?;
            // h.dap_client.seq = ctx.seq;
            // h.respond_to_disconnect(req.clone(), args)?;
            let response_body = dap::DisconnectResponseBody {};
            // copied from `respond_dap` from handler.rs
            let response = DapMessage::Response(dap::Response {
                base: dap::ProtocolMessage {
                    seq: ctx.seq,
                    type_: "response".to_string(),
                },
                request_seq: req.base.seq,
                success: true,
                command: req.command.clone(),
                message: None,
                body: serde_json::to_value(response_body)?,
            });
            ctx.write_dap_messages(sender, &[response])?;

            // Wait briefly until the sending thread confirms the framed disconnect
            // response was written, then terminate the server loop.
            const DISCONNECT_WRITE_TIMEOUT_MS: usize = 2000;
            let mut waited_ms = 0usize;
            while !ctx.disconnect_response_written.load(Ordering::SeqCst) {
                if waited_ms >= DISCONNECT_WRITE_TIMEOUT_MS {
                    return Err("disconnect response was not written before shutdown timeout".into());
                }
                thread::sleep(Duration::from_millis(5));
                waited_ms += 5;
            }
            ctx.should_terminate = true;
        }
        DapMessage::Request(req) => {
            if let Some(to_stable_sender) = ctx.to_stable_sender.clone() {
                to_stable_sender.send(req.clone())?;
            }
        }
        _ => {}
    }

    Ok(())
}

/// Browser/WASM message handler that maintains a [`Handler`] inline.
///
/// In the browser build, threads are unavailable and all DAP messages are
/// processed synchronously in the JS event loop. This function combines the
/// roles of [`handle_message`] (protocol negotiation) and [`task_thread`]
/// (request dispatch) into a single entry point.
///
/// The `handler` parameter is an `Option<Handler>` owned by the caller's
/// closure. It starts as `None` and is populated when `configurationDone`
/// triggers [`setup_from_vfs`].  Subsequent DAP requests (step, variables,
/// etc.) are dispatched directly to this handler.
#[cfg(feature = "browser-transport")]
pub fn handle_message_browser(
    msg: &DapMessage,
    sender: Sender<DapMessage>,
    ctx: &mut Ctx,
    handler: &mut Option<Handler>,
) -> Result<(), Box<dyn Error>> {
    debug!("handle_message_browser: {:?}", msg);

    // Protocol-level messages (initialize, launch, configurationDone,
    // disconnect) are handled exactly like the native path.
    match msg {
        DapMessage::Request(req) if req.command == "initialize" => {
            // Delegate to the shared protocol handler — it only sends
            // initialize + initialized responses.
            handle_message(msg, sender, ctx)?;
        }
        DapMessage::Request(req) if req.command == "launch" => {
            // Store launch parameters in ctx (same as native path).
            handle_message(msg, sender.clone(), ctx)?;

            // In the browser, re-detect the trace file from the VFS.  The
            // native auto-detect uses `Path::is_file()` which always returns
            // false in WASM, so we always re-run detection here using
            // VFS-aware lookups. Materialized traces are CTFS-only.
            {
                let folder = ctx.launch_trace_folder.to_string_lossy().to_string();
                // `trace.ct` is the canonical CTFS container; `trace.json`
                // is the legacy `runtime_tracing` materialized layout still
                // emitted by some recorders (e.g. `nargo trace`).  Probe
                // both so client-side WASM replay works for either.
                let candidates = ["trace.ct", "trace.json"];
                for name in &candidates {
                    let vfs_path = if folder.is_empty() {
                        (*name).to_string()
                    } else {
                        format!("{}/{}", folder.trim_end_matches('/'), name)
                    };
                    if crate::vfs::vfs_exists(&vfs_path) {
                        ctx.launch_trace_file = PathBuf::from(*name);
                        info!("handle_message_browser: VFS auto-detect found trace file: {}", vfs_path);
                        break;
                    }
                }
            }
        }
        DapMessage::Request(req) if req.command == "configurationDone" => {
            // Send the configurationDone response first.
            handle_message(msg, sender.clone(), ctx)?;

            // Now perform the actual trace setup from VFS.
            if handler.is_none() && !ctx.launch_trace_folder.as_os_str().is_empty() {
                let folder = ctx.launch_trace_folder.to_string_lossy().to_string();
                let file = ctx.launch_trace_file.to_string_lossy().to_string();
                info!(
                    "handle_message_browser: configurationDone — setting up from VFS: folder={folder:?}, file={file:?}"
                );

                match setup_from_vfs(
                    &folder,
                    &file,
                    ctx.launch_raw_diff_index.clone(),
                    ctx.restore_location.clone(),
                    sender,
                    true, // for_launch — run_to_entry
                    "browser-stable",
                ) {
                    Ok(h) => {
                        info!(
                            "handle_message_browser: VFS setup succeeded — step_count={}, step_id={:?}",
                            h.reader.step_count(),
                            h.step_id
                        );
                        *handler = Some(h);
                    }
                    Err(e) => {
                        error!("handle_message_browser: VFS setup failed: {e}");
                        return Err(e);
                    }
                }
            }
        }
        DapMessage::Request(req) if req.command == "disconnect" => {
            handle_message(msg, sender, ctx)?;
        }
        DapMessage::Request(req) => {
            // All other requests are dispatched to the handler if it is
            // initialized. If not, the request is dropped with a warning.
            if let Some(h) = handler {
                if h.initialized {
                    if let Err(e) = handle_request(h, req.clone(), sender.clone()) {
                        warn!("handle_message_browser: request {} error: {e}", req.command);
                        let error_response = DapMessage::Response(Response {
                            base: ProtocolMessage {
                                seq: 0,
                                type_: "response".to_string(),
                            },
                            request_seq: req.base.seq,
                            success: false,
                            command: req.command.clone(),
                            message: Some(format!("{e}")),
                            body: json!({}),
                        });
                        sender.send(error_response)?;
                    }
                } else {
                    warn!(
                        "handle_message_browser: handler not initialized, dropping {:?}",
                        req.command
                    );
                }
            } else {
                warn!("handle_message_browser: no handler yet, dropping {:?}", req.command);
            }
        }
        _ => {}
    }

    Ok(())
}

fn task_thread(
    name: &str,
    from_thread_receiver: Receiver<dap::Request>,
    sender: Sender<DapMessage>,
    ctx_with_cached_launch: &Ctx,
    cached_launch: bool,
    run_to_entry: bool,
) -> Result<(), Box<dyn Error>> {
    // Track the trace folder + file currently loaded into `handler` so we can
    // skip a redundant `setup()` reload when the renderer issues a duplicate
    // launch for the SAME trace.  Without this, every materialized DB trace
    // pays the full CTFS Db population cost twice (once from
    // backend-manager's dap_init and once from the renderer's
    // `dap-replay-selected` handshake), which can stretch ct-host startup
    // to 80+ seconds for non-trivial traces and time out tests waiting on
    // `ct/event-load` and `ct/load-calltrace-section` responses that are
    // queued behind the second reload.
    let mut loaded_trace_folder: Option<PathBuf> = None;
    let mut loaded_trace_file: Option<PathBuf> = None;
    let mut loaded_raw_diff_index: Option<String> = None;

    let mut handler = if cached_launch {
        let for_launch = false;
        let h = setup(
            &ctx_with_cached_launch.launch_trace_folder,
            &ctx_with_cached_launch.launch_trace_file,
            ctx_with_cached_launch.launch_raw_diff_index.clone(),
            &ctx_with_cached_launch.recreator_exe,
            ctx_with_cached_launch.restore_location.clone(),
            sender.clone(),
            for_launch,
            name,
        )
        .map_err(|e| {
            error!("launch error: {e:?}");
            format!("launch error: {e:?}")
        })?;
        loaded_trace_folder = Some(ctx_with_cached_launch.launch_trace_folder.clone());
        loaded_trace_file = Some(ctx_with_cached_launch.launch_trace_file.clone());
        loaded_raw_diff_index = ctx_with_cached_launch.launch_raw_diff_index.clone();
        h
    } else {
        // `.initialized` is false
        Handler::new(
            TraceKind::Materialized,
            RecreatorArgs {
                name: name.to_string(),
                ..RecreatorArgs::default()
            },
            Box::new(Db::new(&PathBuf::from(""))),
        )
    };

    loop {
        info!("waiting for new message from DAP server");
        let request = from_thread_receiver.recv().map_err(|e| {
            error!("{name} thread recv error: {e:?}");
            format!("{name} thread recv error: {e:?}")
        })?;

        info!("  try to handle {:?}", request.command);
        if request.command == "launch" {
            let args = request.load_args::<dap::LaunchRequestArguments>()?;
            if let Some(folder) = &args.trace_folder {
                let launch_trace_folder = folder.clone();
                let launch_trace_file = if let Some(trace_file) = &args.trace_file {
                    trace_file.clone()
                } else {
                    // Materialized traces are CTFS-only — pick the first
                    // `.ct` container in the folder, falling back to the
                    // canonical name so setup() yields a clear error if
                    // nothing matches.
                    if let Some(ct_path) = find_ct_file_in_dir(folder) {
                        ct_path
                            .file_name()
                            .map_or_else(|| "trace.ct".into(), |name| name.into())
                    } else {
                        "trace.ct".into()
                    }
                };

                info!("stored launch trace folder: {0:?}", launch_trace_folder);

                let launch_raw_diff_index = args.raw_diff_index.clone();
                // Only resolve the replay-worker executable for non-DB traces
                // (see the parallel comment in the initial launch handler).
                let recreator_exe = if is_db_trace(&launch_trace_folder, &launch_trace_file) {
                    info!("DB-based trace detected — skipping replay-worker resolution");
                    PathBuf::new()
                } else {
                    resolve_recreator_exe(args.recreator_exe)
                };
                let restore_location = args.restore_location.clone();

                // Skip a redundant `setup()` reload when this launch targets
                // the exact trace that the existing handler already serves.
                // Comparison is conservative: same folder + same trace file +
                // same raw_diff_index, and the previous setup completed
                // (`handler.initialized`).  When the launch carries a
                // restore_location we still rerun setup so the position is
                // applied via run_to_entry's restore branch.
                let same_trace = loaded_trace_folder.as_ref() == Some(&launch_trace_folder)
                    && loaded_trace_file.as_ref() == Some(&launch_trace_file)
                    && loaded_raw_diff_index == launch_raw_diff_index
                    && handler.initialized
                    && restore_location.is_none();

                if same_trace {
                    info!(
                        "skipping duplicate launch for already-loaded trace {launch_trace_folder:?}/{launch_trace_file:?}"
                    );
                    // The renderer expects the launch acknowledgement to
                    // happen at the protocol level (handled by the receiving
                    // thread/main thread). We only need to avoid re-running
                    // the expensive CTFS Db population here.
                } else {
                    let for_launch = run_to_entry;
                    handler = setup(
                        &launch_trace_folder,
                        &launch_trace_file,
                        launch_raw_diff_index.clone(),
                        &recreator_exe,
                        restore_location,
                        sender.clone(),
                        for_launch,
                        name,
                    )
                    .map_err(|e| {
                        error!("launch error: {e:?}");
                        format!("launch error: {e:?}")
                    })?;
                    loaded_trace_folder = Some(launch_trace_folder);
                    loaded_trace_file = Some(launch_trace_file);
                    loaded_raw_diff_index = launch_raw_diff_index;
                }
            }
        } else if handler.initialized {
            let res = handle_request(&mut handler, request.clone(), sender.clone());
            if let Err(e) = res {
                warn!("  handle_request error in thread: {e:?}");
                // Send an error response back to the daemon so it does not
                // wait indefinitely for events that will never arrive (e.g.,
                // a `stopped` event after an unrecognized navigation command
                // like `ct/goto-ticks`).
                let error_response = DapMessage::Response(Response {
                    base: ProtocolMessage {
                        seq: 0, // Will be patched by write_dap_messages
                        type_: "response".to_string(),
                    },
                    request_seq: request.base.seq,
                    success: false,
                    command: request.command.clone(),
                    message: Some(format!("{e}")),
                    body: json!({}),
                });
                if let Err(send_err) = sender.send(error_response) {
                    error!("failed to send error response for {}: {send_err:?}", request.command);
                }
                // continue with other requests; trying to be more robust
                // assuming it's for individual requests to fail
                //   TODO: is it possible for some to leave bad state ?
            }
        } else {
            warn!("  handler NOT initialized, dropping {:?}", request.command);
        }
    }
    // Ok(())
}

#[cfg(feature = "io-transport")]
fn handle_client<W>(
    receiver: Receiver<DapMessage>,
    _receiving_thread: &thread::JoinHandle<Result<(), String>>,
    writer: W,
) -> Result<(), Box<dyn Error>>
where
    W: std::io::Write + Send + 'static,
{
    use log::error;

    let mut ctx = Ctx::default();

    // TODO: start stable/other threads here

    let (sending_sender, sending_receiver) = mpsc::channel();

    let builder = thread::Builder::new().name("sending".to_string());
    let disconnect_response_written = ctx.disconnect_response_written.clone();
    let _sending_thread = builder.spawn(move || -> Result<(), String> {
        let mut send_seq = 0i64;
        let mut transport: Box<dyn DapTransport> = Box::new(writer);
        loop {
            info!("wait for next message from dap server/task threads");
            let msg: DapMessage = sending_receiver.recv().map_err(|e| {
                error!("sending thread: recv error: {e:?}");
                format!("sending thread: recv error: {e:?}")
            })?;
            let msg_with_seq = patch_message_seq(&msg, send_seq);
            send_seq += 1;
            transport.send(&msg_with_seq).map_err(|e| {
                error!("transport send error: {e:}");
                format!("transport send error: {e:}")
            })?;
            if let DapMessage::Response(resp) = &msg_with_seq {
                if resp.command == "disconnect" {
                    disconnect_response_written.store(true, Ordering::SeqCst);
                }
            }
        }
    })?;

    let (to_stable_sender, from_stable_receiver) = mpsc::channel::<dap::Request>();
    ctx.to_stable_sender = Some(to_stable_sender);
    let stable_sending_sender = sending_sender.clone();
    let stable_ctx = ctx.clone();

    info!("create stable thread");
    let cached_launch = false;
    let run_to_entry = true;
    let builder = thread::Builder::new().name("stable".to_string());
    let _stable_thread_handle = builder.spawn(move || -> Result<(), String> {
        task_thread(
            "stable",
            from_stable_receiver,
            stable_sending_sender,
            &stable_ctx,
            cached_launch,
            run_to_entry,
        )
        .map_err(|e| {
            error!("task_thread error: {e:?}");
            format!("task_thread error: {e:?}")
        })?;
        Ok(())
    })?;

    // start flow here; send to it
    // or start new each time; send to it?

    let (to_flow_sender, from_flow_receiver) = mpsc::channel::<dap::Request>();
    ctx.to_flow_sender = Some(to_flow_sender);
    let flow_sending_sender = sending_sender.clone();
    let flow_ctx = ctx.clone();

    info!("create flow thread");
    let cached_launch = false;
    let run_to_entry = false;
    let builder = thread::Builder::new().name("flow".to_string());
    let _flow_thread_handle = builder.spawn(move || -> Result<(), String> {
        task_thread(
            "flow",
            from_flow_receiver,
            flow_sending_sender,
            &flow_ctx,
            cached_launch,
            run_to_entry,
        )
        .map_err(|e| {
            error!("task_thread error: {e:?}");
            format!("task_thread error: {e:?}")
        })?;
        Ok(())
    })?;

    let (to_tracepoint_sender, from_tracepoint_receiver) = mpsc::channel::<dap::Request>();
    ctx.to_tracepoint_sender = Some(to_tracepoint_sender);
    let tracepoint_sending_sender = sending_sender.clone();
    let tracepoint_ctx = ctx.clone();

    info!("create tracepoint thread");
    let cached_launch = false;
    let run_to_entry = false;
    let builder = thread::Builder::new().name("tracepoint".to_string());
    let _tracepoint_thread_handle = builder.spawn(move || -> Result<(), String> {
        task_thread(
            "tracepoint",
            from_tracepoint_receiver,
            tracepoint_sending_sender,
            &tracepoint_ctx,
            cached_launch,
            run_to_entry,
        )
        .map_err(|e| {
            error!("task_thread error: {e:?}");
            format!("task_thread error: {e:?}")
        })?;
        Ok(())
    })?;

    loop {
        info!("waiting for new message from receiver");
        let msg = receiver.recv()?;
        // for now only handle requests here
        if let DapMessage::Request(request) = msg.clone() {
            // setups other worker threads
            if request.command == "launch" {
                if let Some(to_flow_sender) = ctx.to_flow_sender.clone() {
                    if let Err(e) = to_flow_sender.send(request.clone()) {
                        error!("flow send launch error: {e:?}");
                    }
                }

                if let Some(to_tracepoint_sender) = ctx.to_tracepoint_sender.clone() {
                    if let Err(e) = to_tracepoint_sender.send(request.clone()) {
                        error!("tracepoint send launch error: {e:?}");
                    }
                }
            }

            // handle all requests here: including `launch` from actually stable thread
            match request.command.as_str() {
                "ct/load-flow" => {
                    if let Some(to_flow_sender) = ctx.to_flow_sender.clone() {
                        if let Err(e) = to_flow_sender.send(request.clone()) {
                            error!("flow send request error: {e:?}");
                        }
                    }
                }
                "ct/event-load"
                | "ct/run-tracepoints"
                | "ct/setup-trace-session"
                | "ct/update-table"
                | "ct/load-terminal"
                | "ct/tracepoint-toggle"
                | "ct/tracepoint-delete"
                | "ct/load-history" => {
                    // TODO: separate load-history
                    if let Some(to_tracepoint_sender) = ctx.to_tracepoint_sender.clone() {
                        if let Err(e) = to_tracepoint_sender.send(request.clone()) {
                            error!("tracepoint send request error: {e:?}");
                        }
                    }
                }
                _ => {
                    // processes or sends to stable
                    // including `launch` again
                    let res = handle_message(&msg, sending_sender.clone(), &mut ctx);
                    if let Err(e) = res {
                        error!("handle_message error: {e:?}");
                    }
                    if ctx.should_terminate {
                        break;
                    }
                }
            }
        }
    }

    Ok(())
}

// ── Tests ──────────────────────────────────────────────────────────────
//
// These tests pin the MCR-detection behaviour added in F5a Phase B for
// the WASM browser-replay path. They drive `is_mcr_ctfs_container`
// directly with crafted CTFS containers because constructing a fully
// initialised `Handler` (the return type of `setup_from_vfs`) requires
// a live DAP message channel and a populated VFS — both heavyweight
// for a unit test.
#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use crate::ctfs_trace_reader::ctfs_container::{CtfsReader, write_minimal_ctfs};
    use crate::ctfs_trace_reader::meta_dat::{
        FLAG_HAS_MCR_FIELDS, META_DAT_VERSION, McrFields, MetaDat, serialize_meta_dat,
    };

    /// Build a `meta.dat` payload with the `FlagHasMcrFields` bit set.
    /// The MCR sub-block is filled with plausible-but-arbitrary values:
    /// we only care that the bit is set so the parser exposes
    /// `mcr.is_some()`.
    fn mcr_meta_dat_bytes() -> Vec<u8> {
        serialize_meta_dat(&MetaDat {
            version: META_DAT_VERSION,
            flags: FLAG_HAS_MCR_FIELDS,
            recording_id: "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb".to_owned(),
            program: "/usr/bin/example".to_owned(),
            args: vec!["arg0".to_owned()],
            workdir: "/tmp/run".to_owned(),
            recorder_id: "mcr".to_owned(),
            paths: vec!["src/main.c".to_owned()],
            mcr: Some(McrFields {
                tick_source: 1,
                total_threads: 1,
                atomic_mode: 0,
                total_events: 0,
                total_checkpoints: 0,
                start_time_unix_us: 0,
                platform: "linux-x86_64".to_owned(),
                tick_granularity: "instruction".to_owned(),
                tick_source_str: "rdtsc".to_owned(),
                atomic_mode_str: "seq_cst".to_owned(),
                start_time_str: "1970-01-01T00:00:00Z".to_owned(),
                hook_profile: String::new(),
                hook_strategies: Vec::new(),
            }),
            replay_launch: None,
            layout_snapshot: None,
            filter_provenance: Vec::new(),
            has_filter_provenance: false,
        })
    }

    /// Build a `meta.dat` payload for a materialised (non-MCR) trace.
    fn non_mcr_meta_dat_bytes() -> Vec<u8> {
        serialize_meta_dat(&MetaDat {
            version: META_DAT_VERSION,
            flags: 0,
            recording_id: "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb".to_owned(),
            program: "/usr/bin/ruby".to_owned(),
            args: vec!["script.rb".to_owned()],
            workdir: "/srv/proj".to_owned(),
            recorder_id: "ruby".to_owned(),
            paths: vec![],
            mcr: None,
            replay_launch: None,
            layout_snapshot: None,
            filter_provenance: Vec::new(),
            has_filter_provenance: false,
        })
    }

    /// Read a fixture container into an in-memory `CtfsReader`.
    fn read_ctfs(path: &Path) -> CtfsReader {
        let bytes = std::fs::read(path).unwrap();
        CtfsReader::from_bytes(bytes).unwrap()
    }

    /// Positive case: a CTFS container whose `meta.dat` has the MCR
    /// flag bit set must be classified as MCR. This mirrors what a live
    /// recording produced by `codetracer-native-recorder` writes.
    #[test]
    fn is_mcr_ctfs_container_detects_flag_has_mcr_fields() {
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("mcr.ct");

        let dat = mcr_meta_dat_bytes();
        // Live MCR traces ship per-thread streams instead of materialised
        // DB files; include a placeholder thread stream to exercise the
        // realistic file layout, even though `is_mcr_ctfs_container`
        // only inspects `meta.dat`.
        write_minimal_ctfs(&ct_path, &[("meta.dat", &dat), ("t00000000000", b"")]).unwrap();

        let mut ctfs = read_ctfs(&ct_path);
        assert!(
            is_mcr_ctfs_container(&mut ctfs),
            "expected meta.dat with FlagHasMcrFields to be classified as MCR",
        );
    }

    /// Negative case: a materialised trace (legacy DB-trace layout)
    /// with `meta.dat` but no MCR fields must NOT be classified as MCR
    /// — otherwise we would regress every existing browser-replay user.
    #[test]
    fn is_mcr_ctfs_container_rejects_materialized_trace() {
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("materialized.ct");

        let dat = non_mcr_meta_dat_bytes();
        write_minimal_ctfs(&ct_path, &[("meta.dat", &dat), ("events.log", b"placeholder")]).unwrap();

        let mut ctfs = read_ctfs(&ct_path);
        assert!(
            !is_mcr_ctfs_container(&mut ctfs),
            "materialised trace without FlagHasMcrFields must not be classified as MCR",
        );
    }

    /// Containers without any `meta.dat` (legacy `meta.json`-only
    /// traces) must not be classified as MCR. The helper has to be
    /// tolerant of missing metadata so callers can fall through to the
    /// JSON fallback path without seeing spurious errors.
    #[test]
    fn is_mcr_ctfs_container_handles_missing_meta_dat() {
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("legacy.ct");

        let meta_json = br#"{"workdir":"/legacy","program":"/legacy/app","args":[]}"#;
        write_minimal_ctfs(&ct_path, &[("meta.json", meta_json)]).unwrap();

        let mut ctfs = read_ctfs(&ct_path);
        assert!(
            !is_mcr_ctfs_container(&mut ctfs),
            "missing meta.dat must not classify as MCR (fall-through to legacy reader)",
        );
    }

    /// A corrupted `meta.dat` is treated as "not classifiable as MCR"
    /// rather than as an error: `setup_from_vfs` will then call
    /// `CTFSTraceReader::from_bytes` which produces a typed error
    /// surfaced to the user. We verify that the helper itself does not
    /// panic on garbage input.
    #[test]
    fn is_mcr_ctfs_container_tolerates_corrupt_meta_dat() {
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("corrupt.ct");

        // Bytes too short to even contain the 8-byte header — guarantees
        // a `MetaDatError::TooShort` from the parser.
        let bad_dat = [0u8; 4];
        write_minimal_ctfs(&ct_path, &[("meta.dat", &bad_dat)]).unwrap();

        let mut ctfs = read_ctfs(&ct_path);
        assert!(
            !is_mcr_ctfs_container(&mut ctfs),
            "corrupt meta.dat must be treated as not-MCR so the typed error surfaces later",
        );
    }
}
