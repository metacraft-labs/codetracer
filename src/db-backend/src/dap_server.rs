use serde_json::{Value, json};
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
// M24 — multi-trace session loading. The dap_server holds onto a
// `SessionHandler` instead of (or rather: wrapping) a single
// `Handler` so requests can route per-thread to the owning trace.
use crate::session_handler::{SessionHandler, TraceSlot, compose_thread_id, decompose_thread_id};
use crate::session_manifest::SessionManifest;
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
    if let Some(ref path) = from_launch_args
        && !path.as_os_str().is_empty()
    {
        info!("ct-native-replay: using path from launch args: {}", path.display());
        return path.clone();
    }

    // 2. Check CODETRACER_CT_NATIVE_REPLAY_CMD environment variable,
    //    falling back to the legacy CODETRACER_CT_RR_SUPPORT_CMD.
    for var_name in &["CODETRACER_CT_NATIVE_REPLAY_CMD", "CODETRACER_CT_RR_SUPPORT_CMD"] {
        if let Ok(env_path) = std::env::var(var_name)
            && !env_path.is_empty()
        {
            info!("ct-native-replay: using path from {}: {}", var_name, env_path);
            return PathBuf::from(env_path);
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
    run_stdio_with_options(None)
}

/// §P5.4 — same as [`run_stdio`] but accepts a CLI-supplied default
/// rename list path.  When provided, the path applies to every trace
/// the server opens unless overridden by a per-launch
/// `LaunchRequestArguments.renameList`.
#[cfg(feature = "io-transport")]
pub fn run_stdio_with_options(cli_default_rename_list: Option<PathBuf>) -> Result<(), Box<dyn Error>> {
    run_with_endpoint_options(DapEndpoint::Stdio, cli_default_rename_list)
}

#[cfg(feature = "io-transport")]
pub fn run(socket_path: &Path) -> Result<(), Box<dyn Error>> {
    run_with_options(socket_path, None)
}

/// §P5.4 — same as [`run`] but accepts a CLI-supplied default rename
/// list path.  See [`run_stdio_with_options`] for the contract.
#[cfg(feature = "io-transport")]
pub fn run_with_options(socket_path: &Path, cli_default_rename_list: Option<PathBuf>) -> Result<(), Box<dyn Error>> {
    #[cfg(windows)]
    {
        // On Windows, the backend-manager passes a TCP address like
        // "127.0.0.1:12345" as the socket path.  Detect this by checking
        // if the path contains a colon followed by digits (host:port format).
        let path_str = socket_path.to_string_lossy();
        if looks_like_tcp_address(&path_str) {
            run_with_endpoint_options(DapEndpoint::TcpSocket(path_str.into_owned()), cli_default_rename_list)
        } else {
            run_with_endpoint_options(
                DapEndpoint::WindowsNamedPipe(path_str.into_owned()),
                cli_default_rename_list,
            )
        }
    }

    #[cfg(not(windows))]
    run_with_endpoint_options(
        DapEndpoint::UnixSocket(socket_path.to_path_buf()),
        cli_default_rename_list,
    )
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
    run_with_endpoint_options(endpoint, None)
}

/// §P5.4 — endpoint-level entry point with the CLI-supplied default
/// rename list path.  See [`run_stdio_with_options`] for the contract.
#[cfg(feature = "io-transport")]
pub fn run_with_endpoint_options(
    endpoint: DapEndpoint,
    cli_default_rename_list: Option<PathBuf>,
) -> Result<(), Box<dyn Error>> {
    use std::io::BufReader;

    match endpoint {
        DapEndpoint::Stdio => {
            let stdin = std::io::stdin();
            let stdout = std::io::stdout();
            run_with_stream_options(BufReader::new(stdin), stdout, cli_default_rename_list)
        }
        DapEndpoint::UnixSocket(socket_path) => {
            #[cfg(unix)]
            {
                let stream = UnixStream::connect(&socket_path)?;
                let writer = stream.try_clone()?;
                info!("stream ok out of thread");
                let reader = BufReader::new(stream);
                run_with_stream_options(reader, writer, cli_default_rename_list)
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
                run_with_stream_options(reader, writer, cli_default_rename_list)
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
            run_with_stream_options(reader, writer, cli_default_rename_list)
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
    run_with_stream_options(reader, writer, None)
}

/// §P5.4 — same as [`run_with_stream`] but accepts a CLI-supplied
/// default rename list path.
#[cfg(feature = "io-transport")]
pub fn run_with_stream_options<R, W>(
    reader: R,
    writer: W,
    cli_default_rename_list: Option<PathBuf>,
) -> Result<(), Box<dyn Error>>
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

    handle_client(receiving_receiver, &receiving_thread, writer, cli_default_rename_list)
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
    rename_list_path: Option<&Path>,
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
                if let Some(decoder) = load_materialized_origin_metadata_decoder_from_path(&ctfs_path) {
                    handler.install_materialized_origin_metadata_decoder(decoder);
                }
                handler.raw_diff_index = raw_diff_index;
                // Load macro sourcemaps for Nim macro expansion support (S6).
                handler.load_macro_sourcemaps(trace_folder);
                // Load Source Map V3 indexes for every recorded source
                // path that has one (P3 — Column-Aware-Tracing-And-
                // Deminification milestone).
                handler.load_sourcemaps(trace_folder);
                // §P6.2 — recorder-baked alternate source views
                // (`srcviews.dat`).  Runs AFTER `load_sourcemaps` so
                // any srcviews record overwrites the sibling-map
                // entry for the same path (the recorder explicitly
                // baked this view).
                handler.load_source_views(trace_folder);
                // §P5 — user-provided variable rename list.
                handler.load_rename_list(trace_folder, rename_list_path);
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
        } else if trace_folder.is_file() && trace_folder.file_name().map(|n| n == "trace.json").unwrap_or(false) {
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
        let events: Vec<codetracer_trace_types::TraceLowLevelEvent> = serde_json::from_slice(&json_bytes)
            .map_err(|e| format!("failed to parse legacy trace.json at {}: {e}", json_path.display()))?;
        // Workdir: prefer `trace_metadata.json` next to `trace.json`,
        // else fall back to the trace folder itself.
        let meta_workdir = json_path
            .parent()
            .map(|d| d.join("trace_metadata.json"))
            .filter(|p| p.is_file())
            .and_then(|p| std::fs::read(&p).ok())
            .and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok())
            .and_then(|v| v.get("workdir").and_then(|w| w.as_str()).map(PathBuf::from));
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
        // P3 — load Source Map V3 indexes for every recorded source.
        handler.load_sourcemaps(trace_folder);
        // §P5 — user-provided variable rename list.
        handler.load_rename_list(trace_folder, rename_list_path);
        if for_launch {
            handler.run_to_entry(dap::Request::default(), restore_location, sender)?;
        }
        handler.initialized = true;
        return Ok(handler);
    }

    // Legacy `runtime_tracing` binary materialized layout: a `trace.bin`
    // file holding the capnp `BinaryV0` event stream (the Python recorder
    // emits this).  It shares the `C0 DE 72 AC E2` magic prefix with a
    // CTFS container but is NOT one — `CtfsReader::open` rejects it on the
    // version byte (0x00 vs the CTFS-required 2..4), so `setup` would
    // otherwise fall through to the rr replay-worker path and fail with
    // "program path has no file name".  Decode it the same way as
    // `trace.json`: read the events, then run the shared `from_events`
    // postprocessing pipeline.
    let legacy_bin_path = {
        let direct = trace_folder.join("trace.bin");
        if direct.is_file() {
            Some(direct)
        } else if trace_folder.is_file() && trace_folder.file_name().map(|n| n == "trace.bin").unwrap_or(false) {
            Some(trace_folder.to_path_buf())
        } else {
            None
        }
    };
    if let Some(bin_path) = legacy_bin_path {
        info!(
            "detected legacy runtime_tracing binary materialized trace: {}",
            bin_path.display()
        );
        use codetracer_trace_reader::trace_readers::TraceReader as _;
        let mut bin_reader = codetracer_trace_reader::trace_readers::BinaryTraceReader {};
        let events = bin_reader
            .load_trace_events(&bin_path)
            .map_err(|e| format!("failed to parse legacy trace.bin at {}: {e}", bin_path.display()))?;
        // Workdir: prefer `trace_metadata.json` next to `trace.bin`,
        // else fall back to the trace folder itself.
        let meta_workdir = bin_path
            .parent()
            .map(|d| d.join("trace_metadata.json"))
            .filter(|p| p.is_file())
            .and_then(|p| std::fs::read(&p).ok())
            .and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok())
            .and_then(|v| v.get("workdir").and_then(|w| w.as_str()).map(PathBuf::from));
        let workdir = meta_workdir.unwrap_or_else(|| {
            bin_path
                .parent()
                .map(|d| d.to_path_buf())
                .unwrap_or_else(|| PathBuf::from("."))
        });
        let reader = CTFSTraceReader::from_events(events, &workdir)?;
        info!(
            "legacy binary materialized trace loaded: {} steps, {} calls, {} events",
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
        // P3 — load Source Map V3 indexes for every recorded source.
        handler.load_sourcemaps(trace_folder);
        // §P5 — user-provided variable rename list.
        handler.load_rename_list(trace_folder, rename_list_path);
        if for_launch {
            handler.run_to_entry(dap::Request::default(), restore_location, sender)?;
        }
        handler.initialized = true;
        return Ok(handler);
    }

    info!("not a CTFS materialized trace; trying replay-worker (MCR / rr / TTD .run) path");
    eprintln!("[db-backend setup] trying rr trace path");
    if let Some(path) = resolve_replay_trace_path(trace_folder, trace_file) {
        let mut db = Db::new(&PathBuf::from(""));
        if path.extension().is_some_and(|ext| ext == std::ffi::OsStr::new("ct")) {
            match CTFSTraceReader::load_native_terminal_events_from_path(&path) {
                Ok(events) if !events.is_empty() => {
                    info!(
                        "native replay-worker setup: loaded {} terminal events from {}",
                        events.len(),
                        path.display()
                    );
                    db.events.extend(events);
                }
                Ok(_) => {}
                Err(e) => {
                    warn!(
                        "native replay-worker setup: failed to load terminal events from {}: {e}",
                        path.display()
                    );
                }
            }
        }
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
            ..RecreatorArgs::default()
        };
        info!("ct_rr_args {:?}", ct_rr_args);
        let mut handler = Handler::new(TraceKind::Recreator, ct_rr_args, Box::new(db));
        handler.raw_diff_index = raw_diff_index;
        // Load macro sourcemaps for Nim macro expansion support (S6).
        handler.load_macro_sourcemaps(trace_folder);
        // P3 — load Source Map V3 indexes for every recorded source.
        handler.load_sourcemaps(trace_folder);
        // §P5 — user-provided variable rename list.
        handler.load_rename_list(trace_folder, rename_list_path);
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

/// Returns true when the launch's `trace_folder`/`trace_file` resolves
/// to a `session.toml` manifest. The check is path-shaped — we accept
/// the manifest either as `trace_folder` itself (the typical CLI
/// invocation: `replay-server dap-server <session.toml>`) or as the
/// concatenation `trace_folder/trace_file`. The latter mirrors the
/// existing `.ct` autodetect in `handle_message`.
fn is_session_manifest_path(path: &Path) -> bool {
    if !path.is_file() {
        return false;
    }
    path.extension().is_some_and(|ext| ext == "toml")
        && path
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name == "session.toml")
}

/// Resolve the path the launch's `trace_folder` + `trace_file` point
/// at. Returns the candidate when it looks like a session manifest,
/// otherwise `None`. Kept distinct from `is_session_manifest_path` so
/// callers can also use the helper for the `Ctx::launch_trace_folder`
/// shape (which may itself be the manifest path).
fn resolve_session_manifest_path(trace_folder: &Path, trace_file: &Path) -> Option<PathBuf> {
    if is_session_manifest_path(trace_folder) {
        return Some(trace_folder.to_path_buf());
    }
    let joined = trace_folder.join(trace_file);
    if is_session_manifest_path(&joined) {
        return Some(joined);
    }
    None
}

/// M24 — load a `session.toml` manifest and build a
/// [`SessionHandler`] by calling the existing single-trace [`setup`]
/// for each `[[trace]]` entry. The single-trace `Handler` code is
/// unchanged: we reuse it through the same call surface a single
/// `.ct` launch would, then wrap the resulting handlers behind the
/// session multiplexer.
#[allow(clippy::too_many_arguments)]
fn setup_session(
    manifest_path: &Path,
    raw_diff_index: Option<String>,
    recreator_exe: &Path,
    restore_location: Option<Location>,
    sender: Sender<DapMessage>,
    for_launch: bool,
    thread_name: &str,
    rename_list_path: Option<&Path>,
) -> Result<SessionHandler, Box<dyn Error>> {
    info!("setup_session: loading manifest from {}", manifest_path.display());
    let manifest = SessionManifest::load(manifest_path)
        .map_err(|e| -> Box<dyn Error> { format!("failed to load session manifest: {e}").into() })?;
    let mut handlers: Vec<Handler> = Vec::with_capacity(manifest.traces.len());
    for (idx, trace) in manifest.traces.iter().enumerate() {
        let resolved = manifest.resolved_trace_path(trace);
        info!(
            "setup_session: loading trace [{idx}] role={} recording_id={} from {}",
            trace.role,
            trace.recording_id,
            resolved.display()
        );
        // The single-trace `setup` resolves the CTFS container by
        // probing both `trace_folder` and `trace_folder/trace_file`.
        // We pass the resolved per-trace path as `trace_folder` and an
        // empty file so the existing autodetect picks it up uniformly
        // for both ".ct" files and ".ct"-containing directories.
        let per_trace_thread_name = format!("{}-{}", thread_name, trace.recording_id);
        // Only the first trace pays the run-to-entry cost; secondary
        // traces are positioned via subsequent DAP requests in the
        // session. This mirrors the §14.1 contract where every trace
        // starts at its own entry until the user steers it.
        let trace_for_launch = for_launch && idx == 0;
        let handler = setup(
            &resolved,
            Path::new(""),
            raw_diff_index.clone(),
            recreator_exe,
            if idx == 0 { restore_location.clone() } else { None },
            sender.clone(),
            trace_for_launch,
            &per_trace_thread_name,
            rename_list_path,
        )
        .map_err(|e| -> Box<dyn Error> {
            format!(
                "failed to load trace [{idx}] (role={}) from {}: {e}",
                trace.role,
                resolved.display()
            )
            .into()
        })?;
        handlers.push(handler);
    }
    let session = SessionHandler::new(manifest, handlers)
        .map_err(|e| -> Box<dyn Error> { format!("failed to build session handler: {e}").into() })?;
    Ok(session)
}

/// M24 backwards-compat helper: wrap a single freshly-loaded
/// [`Handler`] inside a synthetic single-trace [`SessionHandler`] so
/// downstream code routes uniformly through the session layer. The
/// synthetic manifest carries one `[[trace]]` entry whose
/// `default_thread_prefix` is empty, so the single-trace DAP surface
/// (thread id `1`, thread name `<thread 1>`) is preserved
/// byte-for-byte. This is the M24
/// `test_session_handler_single_trace_backcompat` contract.
pub fn wrap_single_trace_as_session(handler: Handler, trace_path: PathBuf) -> Result<SessionHandler, Box<dyn Error>> {
    let manifest = SessionManifest::single_trace(trace_path);
    SessionHandler::new(manifest, vec![handler])
        .map_err(|e| -> Box<dyn Error> { format!("failed to wrap single trace as session: {e}").into() })
}

/// Build the per-slot list of inner thread ids by querying each
/// trace's `ReplaySession::list_processes()`. Mirrors the projection
/// the `Handler::threads` implementation already does — we replicate
/// it here so the SessionHandler can build the aggregated thread list
/// without mutating each handler's internal state.
fn inner_threads_for_slot(
    session: &SessionHandler,
    slot: TraceSlot,
) -> Result<Vec<(u32, String)>, crate::session_handler::SessionHandlerError> {
    let loaded = session
        .trace(slot)
        .ok_or(crate::session_handler::SessionHandlerError::UnknownSlot { slot })?;
    // We do not have `&mut Handler` here, but `list_processes` on the
    // ReplaySession trait is `&mut self`. For M24 we use the
    // pre-cached single-thread fallback the existing `threads`
    // handler also falls back to; the production wiring of multi-thread
    // enumeration per trace is a follow-on once
    // `Handler::collect_thread_descriptors()` lands. The behaviour
    // matches today's `Handler::threads`: when no per-trace process
    // metadata is available, surface one synthetic `<thread 1>`.
    let _ = loaded; // suppress unused-binding warning while still asserting the slot is valid
    Ok(vec![(1, "<thread 1>".to_string())])
}

/// Build the DAP `threads` response from a SessionHandler. The
/// aggregated thread list applies each trace's manifest prefix and
/// surfaces composed thread ids — see `session_handler::compose_thread_id`.
fn build_session_threads_response(session: &SessionHandler) -> Result<Vec<crate::dap_types::Thread>, Box<dyn Error>> {
    let aggregated = session
        .aggregated_thread_list(|slot| inner_threads_for_slot(session, slot))
        .map_err(|e| -> Box<dyn Error> { format!("session threads aggregation failed: {e}").into() })?;
    Ok(aggregated
        .into_iter()
        .map(|t| crate::dap_types::Thread {
            id: t.composed_thread_id,
            name: t.name,
        })
        .collect())
}

/// Build the `ct/listProcesses` payload. Each entry carries the
/// manifest role, recording id, thread count, and the composed thread
/// ids the frontend uses to drive cross-trace navigation.
///
/// The `displayName` field is the basename of the trace's filesystem
/// path (or the recording id when no path is available). It is what
/// the M29 spec example shows the frontend rendering in the process
/// tree row label.
///
/// This builder is shared by the `ct/listProcesses` *request* response
/// path (see [`handle_request_via_session`]) and the
/// `ct/listProcesses` *event* dispatched at session-load (see
/// [`dispatch_session_load_event`]); both surfaces carry the same wire
/// shape so the frontend has a single deserialiser.
fn build_ct_list_processes_response(session: &SessionHandler) -> Result<Value, Box<dyn Error>> {
    let processes = session
        .list_processes(|slot| inner_threads_for_slot(session, slot))
        .map_err(|e| -> Box<dyn Error> { format!("session list_processes failed: {e}").into() })?;
    let processes_json: Vec<Value> = processes
        .into_iter()
        .enumerate()
        .map(|(slot_idx, p)| {
            // Resolve the display name from the manifest entry — this
            // is the basename the spec § M29 5.2 example shows ("frontend.ct").
            // Fall back to the recording id when the path is empty so
            // the wire shape always carries a non-empty label.
            let slot = slot_idx as TraceSlot;
            let display_name = session
                .trace(slot)
                .and_then(|loaded| {
                    loaded
                        .entry
                        .path
                        .file_name()
                        .and_then(|os| os.to_str())
                        .map(|s| s.to_string())
                })
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| p.recording_id.clone());
            json!({
                "recordingId": p.recording_id,
                "role": p.role,
                "displayName": display_name,
                "defaultThreadPrefix": p.default_thread_prefix,
                "threadCount": p.thread_count,
                "threadIds": p.thread_ids,
            })
        })
        .collect();
    Ok(json!({ "processes": processes_json }))
}

/// M29 §5.2 — dispatch a `ct/listProcesses` DAP **event** carrying the
/// freshly-loaded session's process list. Called once at session-load
/// (after every `setup_session` / `wrap_single_trace_as_session`
/// call) so the frontend's process tree populates without having to
/// race a follow-up request.
///
/// The event body is byte-for-byte equivalent to the
/// `ct/listProcesses` request response — the frontend can route both
/// through the same deserialiser. The contract is **idempotent**:
/// every call rebuilds the full snapshot, so re-loading the session
/// (e.g. a fresh `launch` request with new `[[trace]]` entries) yields
/// a complete refreshed process list that supersedes the previous
/// one. Consumers MUST treat each event as a total snapshot, not a
/// delta.
///
/// Errors building the payload are logged but never surfaced to the
/// caller — emission is best-effort; a missing event must not block
/// session bring-up.
pub fn dispatch_session_load_event(session: &SessionHandler, sender: &Sender<DapMessage>) {
    let body = match build_ct_list_processes_response(session) {
        Ok(b) => b,
        Err(e) => {
            warn!("ct/listProcesses event: failed to build payload: {e}");
            return;
        }
    };
    let event = DapMessage::Event(dap::Event {
        base: dap::ProtocolMessage {
            // Sequence number is patched by `write_dap_messages` before
            // the event reaches the wire — passing 0 here matches the
            // existing pattern used by the `initialized` event.
            seq: 0,
            type_: "event".to_string(),
        },
        event: "ct/listProcesses".to_string(),
        body,
    });
    if let Err(e) = sender.send(event) {
        warn!("ct/listProcesses event: failed to enqueue on sender: {e}");
    }
}

/// Extract the `threadId` argument from a DAP request, when present.
/// Returns `None` for requests that have no thread context (most
/// `ct/` request types). The session-aware dispatcher uses the result
/// to route requests; missing thread ids default to slot 0 (the
/// primary trace), matching the single-trace surface.
fn extract_thread_id_from_request(req: &dap::Request) -> Option<i64> {
    if let Some(raw) = req.arguments.get("threadId") {
        if let Some(v) = raw.as_i64() {
            return Some(v);
        }
        if let Some(v) = raw.as_u64() {
            return i64::try_from(v).ok();
        }
    }
    None
}

/// Route a single DAP request through the SessionHandler. The
/// composed thread id selects the trace; requests without a thread id
/// default to slot 0 (the primary trace). The existing
/// `handle_request` then dispatches the request to the selected
/// trace's single-trace `Handler` unchanged.
fn handle_request_via_session(
    session: &mut SessionHandler,
    req: dap::Request,
    sender: Sender<DapMessage>,
) -> Result<(), Box<dyn Error>> {
    // `ct/listProcesses` is the only request handled at the session
    // layer itself — everything else routes down to a per-trace
    // `Handler` exactly as before.
    if req.command == "ct/listProcesses" {
        let body = build_ct_list_processes_response(session)?;
        let response = dap::DapMessage::Response(dap::Response {
            base: dap::ProtocolMessage {
                seq: 0,
                type_: "response".to_string(),
            },
            request_seq: req.base.seq,
            success: true,
            command: req.command.clone(),
            message: None,
            body,
        });
        sender.send(response)?;
        return Ok(());
    }
    // `threads` is special: the single-trace `Handler::threads` only
    // knows about its own trace; for sessions we want the aggregated
    // list. We answer at the session layer rather than per-trace.
    if req.command == "threads" {
        let threads = build_session_threads_response(session)?;
        let body = crate::dap_types::ThreadsResponseBody { threads };
        let response = dap::DapMessage::Response(dap::Response {
            base: dap::ProtocolMessage {
                seq: 0,
                type_: "response".to_string(),
            },
            request_seq: req.base.seq,
            success: true,
            command: req.command.clone(),
            message: None,
            body: serde_json::to_value(body)?,
        });
        sender.send(response)?;
        return Ok(());
    }
    let thread_id = extract_thread_id_from_request(&req).unwrap_or_else(|| {
        // Default to slot 0 + inner thread 1 (the legacy single-thread
        // surface) when the request carries no thread context. This is
        // both the backwards-compat path and the natural default for
        // requests like `restart`, `disconnect`, `ct/setup-trace-session`
        // that aren't thread-scoped.
        compose_thread_id(0, 1).unwrap_or(1)
    });
    let (slot, _) = decompose_thread_id(thread_id);
    if (slot as usize) >= session.trace_count() {
        return Err(format!(
            "DAP {} request: threadId {} references unknown trace slot {}",
            req.command, thread_id, slot
        )
        .into());
    }
    let handler = session
        .handler_for_thread_id_mut(thread_id)
        .ok_or_else(|| -> Box<dyn Error> { "session router: handler lookup failed".into() })?;
    handle_request(handler, req, sender)
}

fn default_live_recording_dir(program: &Path, thread_name: &str) -> PathBuf {
    let program_name = program
        .file_stem()
        .and_then(|name| name.to_str())
        .filter(|name| !name.is_empty())
        .unwrap_or("program");
    std::env::temp_dir().join(format!(
        "codetracer-live-{}-{}-{}",
        std::process::id(),
        thread_name,
        program_name
    ))
}

struct LiveProgramSetup {
    program: PathBuf,
    program_args: Vec<String>,
    cwd: Option<PathBuf>,
    live_recording_dir: Option<PathBuf>,
}

fn setup_live_program(
    live_setup: LiveProgramSetup,
    recreator_exe: &Path,
    sender: Sender<DapMessage>,
    for_launch: bool,
    thread_name: &str,
    rename_list_path: Option<&Path>,
) -> Result<Handler, Box<dyn Error>> {
    let live_recording_dir = live_setup
        .live_recording_dir
        .unwrap_or_else(|| default_live_recording_dir(&live_setup.program, thread_name));
    info!(
        "run setup_live_program() for {} with sink {}",
        live_setup.program.display(),
        live_recording_dir.display()
    );
    std::fs::create_dir_all(&live_recording_dir)?;
    let db = Db::new(&PathBuf::from(""));
    let ct_rr_args = RecreatorArgs {
        worker_exe: PathBuf::from(recreator_exe),
        rr_trace_folder: live_recording_dir.clone(),
        name: thread_name.to_string(),
        live_program: Some(live_setup.program),
        live_program_args: live_setup.program_args,
        live_cwd: live_setup.cwd,
        live_recording_dir: Some(live_recording_dir.clone()),
        recording_id: String::new(),
    };
    info!("live ct_rr_args {:?}", ct_rr_args);
    let mut handler = Handler::new(TraceKind::Recreator, ct_rr_args, Box::new(db));
    handler.load_macro_sourcemaps(&live_recording_dir);
    // P3 — load Source Map V3 indexes for every recorded source.
    handler.load_sourcemaps(&live_recording_dir);
    // §P5 — user-provided variable rename list.
    handler.load_rename_list(&live_recording_dir, rename_list_path);
    if for_launch {
        handler.run_to_entry(dap::Request::default(), None, sender)?;
    }
    handler.initialized = true;
    Ok(handler)
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

            let origin_metadata_decoder = load_materialized_origin_metadata_decoder_from_bytes(bytes.clone());
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
                    if let Some(decoder) = origin_metadata_decoder {
                        handler.install_materialized_origin_metadata_decoder(decoder);
                    }
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
    let json_candidates = [join_vfs(trace_folder, "trace.json"), trace_folder.to_string()];
    for candidate in &json_candidates {
        if !crate::vfs::vfs_exists(candidate) || !candidate.ends_with("trace.json") {
            continue;
        }
        let json_bytes = match crate::vfs::vfs_read(candidate) {
            Some(b) => b,
            None => continue,
        };
        info!("setup_from_vfs: detected legacy materialized trace.json at VFS path {candidate:?}");
        let events: Vec<codetracer_trace_types::TraceLowLevelEvent> = serde_json::from_slice(&json_bytes)
            .map_err(|e| format!("failed to parse legacy trace.json at {candidate:?}: {e}"))?;
        // Workdir: prefer `trace_metadata.json` alongside `trace.json` in
        // the VFS, else fall back to the trace folder.
        let meta_vfs = join_vfs(trace_folder, "trace_metadata.json");
        let workdir = crate::vfs::vfs_read(&meta_vfs)
            .and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok())
            .and_then(|v| v.get("workdir").and_then(|w| w.as_str()).map(PathBuf::from))
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
    let mut subdirs = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_file() {
            if path.extension().is_some_and(|ext| ext == "ct") {
                return Some(path);
            }
        } else if path.is_dir()
            && path
                .file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|name| !name.starts_with('.'))
        {
            subdirs.push(path);
        }
    }
    for subdir in subdirs {
        if let Ok(entries) = std::fs::read_dir(&subdir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().is_some_and(|ext| ext == "ct") && path.is_file() {
                    return Some(path);
                }
            }
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

/// Classify a CTFS container as a DB (materialized) trace this backend can
/// serve.
///
/// A container qualifies if it carries EITHER stream layout:
///   - `steps.dat` — the PRODUCTION split-stream format. Every live recorder
///     (Ruby/Python/JS/shell, via the Nim `MultiStreamTraceWriter` FFI) emits
///     this and NEVER `events.log`; `CTFSTraceReader::open` serves it through
///     `open_new_format_nim` (the split streams are read directly, `events.log`
///     is never consulted). This is the canonical path.
///   - `events.log` — the LEGACY/secondary fallback layout: the secondary Rust
///     `CtfsTraceWriter`'s combined stream and test fixtures. It is NOT produced
///     by live recording. We still accept it here so legacy/test bundles open;
///     `CTFSTraceReader::open` routes them through `open_old_format`
///     (`TraceProcessor::postprocess`). See `M23e` in
///     `Trace-Based-Incremental-Testing.milestones.org` for the bounding.
fn is_codetracer_ctfs_file(path: &Path) -> bool {
    let Ok(reader) = CtfsReader::open(path) else {
        return false;
    };
    reader.has_file("steps.dat") || reader.has_file("events.log")
}

fn load_materialized_origin_metadata_decoder_from_path(
    path: &Path,
) -> Option<crate::origin_metadata_indexer::OriginMetadataDecoder> {
    let mut ctfs = CtfsReader::open(path).ok()?;
    load_materialized_origin_metadata_decoder(&mut ctfs)
}

fn load_materialized_origin_metadata_decoder_from_bytes(
    bytes: Vec<u8>,
) -> Option<crate::origin_metadata_indexer::OriginMetadataDecoder> {
    let mut ctfs = CtfsReader::from_bytes(bytes).ok()?;
    load_materialized_origin_metadata_decoder(&mut ctfs)
}

fn load_materialized_origin_metadata_decoder(
    ctfs: &mut CtfsReader,
) -> Option<crate::origin_metadata_indexer::OriginMetadataDecoder> {
    let originmeta_bytes = ctfs
        .read_file(crate::origin_metadata_indexer::CTFS_ORIGINMETA_FILE)
        .ok()?;
    let source_exprs_bytes = match ctfs.read_file(crate::origin_metadata_indexer::CTFS_SOURCE_EXPRS_FILE) {
        Ok(bytes) => bytes,
        Err(e) => {
            warn!(
                "materialized trace has {} but not {}: {e}",
                crate::origin_metadata_indexer::CTFS_ORIGINMETA_FILE,
                crate::origin_metadata_indexer::CTFS_SOURCE_EXPRS_FILE
            );
            return None;
        }
    };
    match crate::origin_metadata_indexer::OriginMetadataDecoder::load(&originmeta_bytes, &source_exprs_bytes) {
        Some(decoder) => Some(decoder),
        None => {
            warn!(
                "could not parse materialized {} / {}; falling back to source classifier",
                crate::origin_metadata_indexer::CTFS_ORIGINMETA_FILE,
                crate::origin_metadata_indexer::CTFS_SOURCE_EXPRS_FILE
            );
            None
        }
    }
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
    // The binary `meta.dat` carries an explicit `FLAG_HAS_MCR_FIELDS`
    // bit. Legacy `meta.json` sidecars are no longer supported.
    if let Ok(bytes) = ctfs.read_file("meta.dat")
        && let Ok(meta) = crate::ctfs_trace_reader::meta_dat::parse_meta_dat(&bytes)
    {
        return meta.mcr.is_some();
    }
    false
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
        // Value Origin Tracking — `ct/originChain` (spec §5.3) and
        // `ct/originSummary` (spec §5.3.2 batch placeholder fill).
        "ct/originChain" => handler.origin_chain(
            req.clone(),
            req.load_args::<crate::task::CtOriginChainArguments>()?,
            sender.clone(),
        )?,
        "ct/originSummary" => handler.origin_summary(
            req.clone(),
            req.load_args::<crate::task::CtOriginSummaryArguments>()?,
            sender.clone(),
        )?,
        // M21 — State Pane settings sub-menu indicator (spec §3.7 +
        // M21 deliverable #4). Returns the active trace's eager-mode
        // class as a string ("on" / "lazy" / "off" / "unavailable").
        "ct/originMode" => handler.origin_mode(req.clone(), sender.clone())?,
        // M25b — Event Log correlation-marker counterpart lookup.
        // Returns the cached counterparts of a `(boundary_id,
        // direction, key_value)` triple via the per-handler pair
        // index. The Event Log surface uses this on a Send marker
        // row's click to render the `→ recv (role:thread)` jump
        // button per spec §5.3.
        "ct/pairIndexLookup" => handler.pair_index_lookup(
            req.clone(),
            req.load_args::<crate::dap_handler::PairIndexLookupArguments>()?,
            sender.clone(),
        )?,
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
        "ct/timeline-seek" => {
            let args = req.load_args::<Value>()?;
            let raw_ticks = args
                .get("rrTicks")
                .or_else(|| args.get("ticks"))
                .ok_or("ct/timeline-seek requires rrTicks")?;
            let ticks = if let Some(ticks) = raw_ticks.as_i64() {
                ticks
            } else if let Some(ticks) = raw_ticks.as_u64() {
                i64::try_from(ticks).map_err(|_| "ct/timeline-seek rrTicks does not fit in i64")?
            } else {
                return Err("ct/timeline-seek rrTicks must be an integer".into());
            };
            handler.goto_ticks(req.clone(), GoToTicksArguments { thread_id: 0, ticks }, sender.clone())?
        }
        "ct/load-flow" => handler.load_flow(req.clone(), req.load_args::<CtLoadFlowArguments>()?, sender.clone())?,
        "ct/run-to-entry" => handler.run_to_entry(req.clone(), None, sender.clone())?,
        "ct/mcr-live-step" => handler.mcr_live_step(
            req.clone(),
            req.load_args::<crate::dap_handler::McrLiveStepArguments>()?,
            sender.clone(),
        )?,
        "ct/mcr-get-recording-head" => handler.mcr_get_recording_head(req.clone(), sender.clone())?,
        "ct/mcr-restore-at" | "ct/live-restore-at" => handler.mcr_restore_at(
            req.clone(),
            req.load_args::<crate::dap_handler::McrRestoreAtArguments>()?,
            sender.clone(),
        )?,
        "ct/seek-to-geid" => handler.seek_to_geid(
            req.clone(),
            req.load_args::<crate::dap_handler::SeekToGeidArguments>()?,
            sender.clone(),
        )?,
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
        "ct/set-active-source-view" => {
            // M3 — Column-Aware-Replay-Navigation §M3.  Toggle the
            // formatted-view step-over runner: when ``viewPath`` is a
            // non-empty string the handler treats subsequent DAP
            // ``next`` requests as formatted-view step-overs (advance
            // one formatted line/statement per press); when ``null``
            // or omitted the runner falls back to the legacy minified-
            // coordinate behaviour.
            let args = req.load_args::<Value>()?;
            let view_path = args
                .get("viewPath")
                .and_then(|v| v.as_str())
                .filter(|s| !s.is_empty())
                .map(|s| s.to_string());
            handler.set_active_source_view(view_path);
            handler.respond_dap(req, 0, sender.clone())?;
        }
        "ct/install-source-view" => {
            // M3 — test-only entry point that injects a synthetic
            // SourceView under a recorded path.  Used by the headless
            // ViewModel and GUI Playwright tests so the formatted-view
            // runner can be exercised without depending on the JS
            // recorder's autoformat step (which would tie the M3
            // contract to ``prettier`` availability at test time).
            //
            // Production code uses [`Handler::load_source_views`] which
            // reads ``srcviews.dat`` from the CTFS container — the
            // installed indexes flow through the exact same
            // ``sourcemap_cache`` slot the test hook writes to, so
            // both paths exercise the same downstream runner code.
            let args = req.load_args::<Value>()?;
            let recorded_path = args
                .get("recordedPath")
                .and_then(|v| v.as_str())
                .ok_or("ct/install-source-view requires recordedPath")?;
            let formatted_view_path = args
                .get("formattedViewPath")
                .and_then(|v| v.as_str())
                .ok_or("ct/install-source-view requires formattedViewPath")?;
            let sourcemap_v3_json = args
                .get("sourcemapV3Json")
                .and_then(|v| v.as_str())
                .ok_or("ct/install-source-view requires sourcemapV3Json")?;
            handler.install_source_view_for_test(recorded_path, formatted_view_path, sourcemap_v3_json.as_bytes())?;
            handler.respond_dap(req, 0, sender.clone())?;
        }
        _ => {
            // M2 — `next` carries an optional `granularity` field that
            // the legacy `dap_command_to_step_action` dispatch dropped
            // on the floor (the comment `for now ignoring arguments`
            // refers exactly to this).  We MUST read it here so the
            // statement-granularity runner gets activated when the
            // client opts in; line/instruction/None all keep routing
            // through the legacy `Action::Next` path for back-compat.
            //
            // Spec: codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org §M2.
            if req.command == "next" {
                let granularity = req
                    .load_args::<dap_types::NextArguments>()
                    .ok()
                    .and_then(|args| args.granularity);
                handler.next_dap(req, granularity, sender.clone())?;
                return Ok(());
            }
            // M7 — `stepBack` carries the same optional `granularity`
            // field (DAP §StepBackArguments).  Symmetric to the M2
            // forward dispatch: we MUST read it here so the
            // column-aware backward statement runner gets activated
            // when the client opts in; line / instruction / None all
            // keep routing through the legacy reverse-`next` path so
            // existing reverse-step UX (F9 / Ctrl+Shift+F10 / etc.)
            // remains bit-for-bit identical.
            //
            // Spec: codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org §M7.
            if req.command == "stepBack" {
                let granularity = req
                    .load_args::<dap_types::StepBackArguments>()
                    .ok()
                    .and_then(|args| args.granularity);
                handler.step_back_dap(req, granularity, sender.clone())?;
                return Ok(());
            }
            // M8 — `stepIn` / `stepOut` are the formatted-view
            // counterparts of the M3 `next` dispatch.  We intercept
            // them here so the active-source-view-aware runner can
            // project each candidate step through the sourcemap_cache
            // and stop at a formatted (line, column) boundary instead
            // of advancing by minified coordinates.  Without an active
            // source view the M8 dispatcher transparently falls
            // through to the legacy `step_in` / `step_out` (via
            // `dap_command_to_step_action`) so back-compat is
            // bit-for-bit identical for clients that haven't opted
            // in.  Reverse-direction `ct/reverseStepIn` /
            // `ct/reverseStepOut` continue to flow through the
            // legacy path — reverse-formatted projection is out of
            // M8 scope, matching M7's stance on reverse-step-back.
            //
            // Spec: codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org §M8.
            if req.command == "stepIn" {
                handler.step_in_dap(req, sender.clone())?;
                return Ok(());
            }
            if req.command == "stepOut" {
                handler.step_out_dap(req, sender.clone())?;
                return Ok(());
            }
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
    /// Column-Aware-Tracing-And-Deminification §P5.4 — explicit path to
    /// a user-provided rename list (TOML).  When `Some(_)` the trace-
    /// open hook uses this path; when `None` it falls back to the
    /// CLI default (`cli_default_rename_list`) or the sibling lookup
    /// `<recording-dir>/renames.toml`.
    pub launch_rename_list: Option<PathBuf>,
    /// CLI-supplied default rename list path
    /// (`replay-server dap-server --rename-list <p>`).  Applies to
    /// every trace the server opens unless overridden by a per-launch
    /// `LaunchRequestArguments.renameList`.
    pub cli_default_rename_list: Option<PathBuf>,
    pub launch_program: Option<PathBuf>,
    pub launch_program_args: Vec<String>,
    pub launch_cwd: Option<PathBuf>,
    pub launch_live_recording_dir: Option<PathBuf>,
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
            launch_rename_list: None,
            cli_default_rename_list: None,
            launch_program: None,
            launch_program_args: Vec::new(),
            launch_cwd: None,
            launch_live_recording_dir: None,
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
                // M-capability-flags: the `initialize` response is
                // sent before any trace has been loaded, so we can't
                // know yet whether per-column affordances should be
                // exposed.  Leave the capability bits absent (the
                // serde wrapper skips `None` so the JSON keys are
                // omitted entirely) and let the per-trace launch
                // path overwrite them.  GUI consumers treat absent
                // = false (the safe back-compat default).
                supports_column_breakpoints: None,
                supports_column_motions: None,
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
                ctx.launch_program = None;
                ctx.launch_program_args.clear();
                ctx.launch_cwd = None;
                ctx.launch_live_recording_dir = None;
                if let Some(trace_file) = &args.trace_file {
                    ctx.launch_trace_file = trace_file.clone();
                } else if is_session_manifest_path(folder) {
                    // M24 session.toml — the manifest declares its own
                    // trace list, so there is no per-launch trace_file
                    // to resolve.
                    ctx.launch_trace_file = PathBuf::new();
                } else {
                    // Auto-detect the trace file. Materialized traces are
                    // CTFS-only (`<program>.ct` or `trace.ct`); legacy
                    // sidecars (`trace.bin` / `trace.json` +
                    // `trace_metadata.json`) are no longer supported.
                    if let Some(ct_path) = find_ct_file_in_dir(folder) {
                        let rel_path = ct_path
                            .strip_prefix(folder)
                            .map(|p| p.to_path_buf())
                            .unwrap_or_else(|_| ct_path.file_name().map(PathBuf::from).unwrap_or(ct_path));
                        ctx.launch_trace_file = rel_path;
                    } else {
                        // No .ct found; default to "trace.ct" so the error
                        // message in setup() points at the canonical name.
                        ctx.launch_trace_file = "trace.ct".into();
                    }
                }

                // TODO: log this when logging logic is properly abstracted
                //info!("stored launch trace folder: {0:?}", ctx.launch_trace_folder)

                ctx.launch_raw_diff_index = args.raw_diff_index.clone();
                // §P5.4: per-launch arg wins; fall back to CLI default
                // when the DAP `launch.renameList` field is unset.
                ctx.launch_rename_list = args.rename_list.clone().or_else(|| ctx.cli_default_rename_list.clone());

                // Only resolve the replay-worker executable for non-DB traces.
                // DB-based traces (JavaScript, Python, Ruby, etc.) never use
                // the rr replay worker; auto-discovering ct-native-replay on
                // PATH for these traces would cause a spurious worker start
                // that fails and blocks trace loading.
                ctx.recreator_exe =
                    if resolve_session_manifest_path(&ctx.launch_trace_folder, &ctx.launch_trace_file).is_some() {
                        // M24 — the session loader resolves the recreator
                        // exe per-trace through the same paths the
                        // single-trace launch uses; the session-level
                        // value is unused.
                        PathBuf::new()
                    } else if is_db_trace(&ctx.launch_trace_folder, &ctx.launch_trace_file) {
                        info!("DB-based trace detected — skipping replay-worker resolution");
                        PathBuf::new()
                    } else {
                        resolve_recreator_exe(args.recreator_exe)
                    };
                ctx.restore_location = args.restore_location.clone();

                if ctx.received_configuration_done
                    && let Some(to_stable_sender) = ctx.to_stable_sender.clone()
                {
                    to_stable_sender.send(req.clone())?;
                }
            } else if let Some(program) = &args.program {
                ctx.launch_program = Some(PathBuf::from(program));
                ctx.launch_program_args = args.args.clone().unwrap_or_default();
                ctx.launch_cwd = args.cwd.as_ref().map(PathBuf::from);
                ctx.launch_live_recording_dir = args.live_recording_dir.clone();
                ctx.launch_trace_folder = PathBuf::new();
                ctx.launch_trace_file = PathBuf::new();
                ctx.launch_raw_diff_index = args.raw_diff_index.clone();
                ctx.launch_rename_list = args.rename_list.clone().or_else(|| ctx.cli_default_rename_list.clone());
                ctx.recreator_exe = resolve_recreator_exe(args.recreator_exe);
                ctx.restore_location = args.restore_location.clone();

                if ctx.received_configuration_done
                    && let Some(to_stable_sender) = ctx.to_stable_sender.clone()
                {
                    to_stable_sender.send(req.clone())?;
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
            if let Some(launch_request) = ctx.launch_request.clone()
                && let Some(to_stable_sender) = ctx.to_stable_sender.clone()
            {
                to_stable_sender.send(launch_request)?;
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
            if let Some(to_stable_sender) = ctx.to_stable_sender.clone()
                && let Err(send_err) = to_stable_sender.send(req.clone())
            {
                // The stable task-thread's ``from_stable_receiver``
                // has been dropped — almost always because the
                // thread panicked.  Surface an error DAP response
                // to the client so its ``customRequest`` promise
                // resolves immediately instead of waiting the full
                // 30 s for nothing (see the Leo deep-test
                // ``can search the calltrace`` failure pattern:
                // the assertion in ``calltrace::load_callstack``
                // panicked on a step with ``call_key == NO_KEY``,
                // the stable thread died silently, and subsequent
                // requests timed out).
                error!(
                    "to_stable_sender.send({}) failed -- stable task-thread is gone ({send_err:?}); \
                     replying success=false so the DAP client doesn't hang",
                    req.command,
                );
                let error_response = DapMessage::Response(dap::Response {
                    base: dap::ProtocolMessage {
                        seq: ctx.seq,
                        type_: "response".to_string(),
                    },
                    request_seq: req.base.seq,
                    success: false,
                    command: req.command.clone(),
                    message: Some(format!(
                        "stable task-thread has exited (likely panicked); cannot service {}",
                        req.command,
                    )),
                    body: json!({}),
                });
                ctx.seq += 1;
                if let Err(reply_err) = sender.send(error_response) {
                    error!("could not send error response for {}: {reply_err:?}", req.command);
                }
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
    // Track the trace folder + file currently loaded into `session` so we can
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

    // M24 — every dispatch path routes through a [`SessionHandler`].
    // The single-trace flow synthesises a one-entry session via
    // [`wrap_single_trace_as_session`] so the per-request routing
    // surface is the same whether the launch points at a `.ct` file
    // or a `session.toml`.
    let mut session: SessionHandler = if cached_launch {
        let for_launch = false;
        let cached_path = ctx_with_cached_launch.launch_trace_folder.clone();
        // First try the session.toml path. When the cached launch
        // points at a `session.toml`, route through `setup_session`;
        // otherwise fall back to the legacy single-trace flow.
        let session_manifest_path = if ctx_with_cached_launch.launch_program.is_none() {
            resolve_session_manifest_path(
                &ctx_with_cached_launch.launch_trace_folder,
                &ctx_with_cached_launch.launch_trace_file,
            )
        } else {
            None
        };
        let s = if let Some(manifest_path) = session_manifest_path {
            setup_session(
                &manifest_path,
                ctx_with_cached_launch.launch_raw_diff_index.clone(),
                &ctx_with_cached_launch.recreator_exe,
                ctx_with_cached_launch.restore_location.clone(),
                sender.clone(),
                for_launch,
                name,
                ctx_with_cached_launch.launch_rename_list.as_deref(),
            )
            .map_err(|e| {
                error!("launch error (session): {e:?}");
                format!("launch error: {e:?}")
            })?
        } else {
            let h = if let Some(program) = &ctx_with_cached_launch.launch_program {
                setup_live_program(
                    LiveProgramSetup {
                        program: program.clone(),
                        program_args: ctx_with_cached_launch.launch_program_args.clone(),
                        cwd: ctx_with_cached_launch.launch_cwd.clone(),
                        live_recording_dir: ctx_with_cached_launch.launch_live_recording_dir.clone(),
                    },
                    &ctx_with_cached_launch.recreator_exe,
                    sender.clone(),
                    for_launch,
                    name,
                    ctx_with_cached_launch.launch_rename_list.as_deref(),
                )
            } else {
                setup(
                    &ctx_with_cached_launch.launch_trace_folder,
                    &ctx_with_cached_launch.launch_trace_file,
                    ctx_with_cached_launch.launch_raw_diff_index.clone(),
                    &ctx_with_cached_launch.recreator_exe,
                    ctx_with_cached_launch.restore_location.clone(),
                    sender.clone(),
                    for_launch,
                    name,
                    ctx_with_cached_launch.launch_rename_list.as_deref(),
                )
            }
            .map_err(|e| {
                error!("launch error: {e:?}");
                format!("launch error: {e:?}")
            })?;
            // M24 backwards-compat: wrap the freshly-loaded
            // single-trace `Handler` in a synthetic `SessionHandler`
            // so the per-request routing surface is uniform.
            wrap_single_trace_as_session(h, cached_path.clone())
                .map_err(|e| -> String { format!("launch error (session wrap): {e:?}") })?
        };
        if ctx_with_cached_launch.launch_program.is_none() {
            loaded_trace_folder = Some(ctx_with_cached_launch.launch_trace_folder.clone());
            loaded_trace_file = Some(ctx_with_cached_launch.launch_trace_file.clone());
            loaded_raw_diff_index = ctx_with_cached_launch.launch_raw_diff_index.clone();
        }
        // M29 §5.2 — emit `ct/listProcesses` on session-load. The
        // cached-launch path has just built a productive
        // SessionHandler (manifest-driven or single-trace wrap); the
        // frontend's process tree consumes this event without having
        // to race a follow-up request. Idempotent on re-load — every
        // launch dispatches a fresh snapshot.
        dispatch_session_load_event(&s, &sender);
        s
    } else {
        // No cached launch yet → synthesise an empty single-trace
        // session whose underlying Handler has `.initialized == false`.
        // Requests are dropped until a `launch` arrives.
        // M29 §5.2 — no event is dispatched here: the placeholder
        // carries no real recording, and emitting at this point would
        // surface a misleading "no processes loaded" snapshot. The
        // event will fire from the subsequent `launch` branch once
        // the real session.toml / single-trace is materialised.
        let placeholder = Handler::new(
            TraceKind::Materialized,
            RecreatorArgs {
                name: name.to_string(),
                ..RecreatorArgs::default()
            },
            Box::new(Db::new(&PathBuf::from(""))),
        );
        wrap_single_trace_as_session(placeholder, PathBuf::from(""))
            .map_err(|e| -> String { format!("placeholder session wrap error: {e:?}") })?
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
                } else if is_session_manifest_path(folder) {
                    // M24 — session.toml carries its own trace list, so
                    // there is no per-launch `trace_file` to resolve.
                    PathBuf::new()
                } else {
                    // Materialized traces are CTFS-only — pick the first
                    // `.ct` container in the folder, falling back to the
                    // canonical name so setup() yields a clear error if
                    // nothing matches.
                    if let Some(ct_path) = find_ct_file_in_dir(folder) {
                        ct_path
                            .strip_prefix(folder)
                            .map(|p| p.to_path_buf())
                            .unwrap_or_else(|_| ct_path.file_name().map(PathBuf::from).unwrap_or(ct_path))
                    } else {
                        "trace.ct".into()
                    }
                };

                info!("stored launch trace folder: {0:?}", launch_trace_folder);

                let launch_raw_diff_index = args.raw_diff_index.clone();
                let session_manifest_path = resolve_session_manifest_path(&launch_trace_folder, &launch_trace_file);
                // Only resolve the replay-worker executable for non-DB traces
                // (see the parallel comment in the initial launch handler).
                let recreator_exe = if session_manifest_path.is_some() {
                    // Session loader resolves per-trace recreator exes
                    // through the same paths the single-trace launch
                    // uses; the per-session value is unused.
                    PathBuf::new()
                } else if is_db_trace(&launch_trace_folder, &launch_trace_file) {
                    info!("DB-based trace detected — skipping replay-worker resolution");
                    PathBuf::new()
                } else {
                    resolve_recreator_exe(args.recreator_exe.clone())
                };
                let restore_location = args.restore_location.clone();

                // Skip a redundant `setup()` reload when this launch targets
                // the exact trace that the existing handler already serves.
                // Comparison is conservative: same folder + same trace file +
                // same raw_diff_index, and the previous setup completed,
                // and the previous run was already a session-or-single-trace
                // initialised cleanly.  When the launch carries a
                // restore_location we still rerun setup so the position is
                // applied via run_to_entry's restore branch.
                let session_initialized = session.trace(0).map(|t| t.handler.initialized).unwrap_or(false);
                let same_trace = loaded_trace_folder.as_ref() == Some(&launch_trace_folder)
                    && loaded_trace_file.as_ref() == Some(&launch_trace_file)
                    && loaded_raw_diff_index == launch_raw_diff_index
                    && session_initialized
                    && restore_location.is_none();

                if same_trace {
                    info!(
                        "skipping duplicate launch for already-loaded trace {launch_trace_folder:?}/{launch_trace_file:?}"
                    );
                    // The renderer expects the launch acknowledgement to
                    // happen at the protocol level (handled by the receiving
                    // thread/main thread). We only need to avoid re-running
                    // the expensive CTFS Db population here.
                } else if let Some(manifest_path) = session_manifest_path {
                    // M24 session.toml launch
                    let for_launch = run_to_entry;
                    // §P5.4 — per-launch arg wins; CLI default fills in.
                    let effective_rename_list = args
                        .rename_list
                        .clone()
                        .or_else(|| ctx_with_cached_launch.cli_default_rename_list.clone());
                    session = setup_session(
                        &manifest_path,
                        launch_raw_diff_index.clone(),
                        &recreator_exe,
                        restore_location,
                        sender.clone(),
                        for_launch,
                        name,
                        effective_rename_list.as_deref(),
                    )
                    .map_err(|e| {
                        error!("session launch error: {e:?}");
                        format!("session launch error: {e:?}")
                    })?;
                    // M29 §5.2 — emit `ct/listProcesses` on
                    // session.toml re-load. Idempotent: each launch
                    // produces a fresh full snapshot.
                    dispatch_session_load_event(&session, &sender);
                    loaded_trace_folder = Some(launch_trace_folder);
                    loaded_trace_file = Some(launch_trace_file);
                    loaded_raw_diff_index = launch_raw_diff_index;
                } else {
                    let for_launch = run_to_entry;
                    // §P5.4 — per-launch arg wins; CLI default fills in.
                    let effective_rename_list = args
                        .rename_list
                        .clone()
                        .or_else(|| ctx_with_cached_launch.cli_default_rename_list.clone());
                    let handler = setup(
                        &launch_trace_folder,
                        &launch_trace_file,
                        launch_raw_diff_index.clone(),
                        &recreator_exe,
                        restore_location,
                        sender.clone(),
                        for_launch,
                        name,
                        effective_rename_list.as_deref(),
                    )
                    .map_err(|e| {
                        error!("launch error: {e:?}");
                        format!("launch error: {e:?}")
                    })?;
                    session = wrap_single_trace_as_session(handler, launch_trace_folder.clone())
                        .map_err(|e| -> String { format!("session wrap error: {e:?}") })?;
                    // M29 §5.2 — emit `ct/listProcesses` on single-
                    // trace launch. The synthetic single-trace
                    // session yields a one-entry process list with the
                    // recorded `.ct` file as `displayName`.
                    dispatch_session_load_event(&session, &sender);
                    loaded_trace_folder = Some(launch_trace_folder);
                    loaded_trace_file = Some(launch_trace_file);
                    loaded_raw_diff_index = launch_raw_diff_index;
                }
            }
            if let Some(program) = &args.program
                && args.trace_folder.is_none()
            {
                let for_launch = run_to_entry;
                let recreator_exe = resolve_recreator_exe(args.recreator_exe.clone());
                // §P5.4 — per-launch arg wins; CLI default fills in.
                let effective_rename_list = args
                    .rename_list
                    .clone()
                    .or_else(|| ctx_with_cached_launch.cli_default_rename_list.clone());
                let handler = setup_live_program(
                    LiveProgramSetup {
                        program: PathBuf::from(program),
                        program_args: args.args.clone().unwrap_or_default(),
                        cwd: args.cwd.as_ref().map(PathBuf::from),
                        live_recording_dir: args.live_recording_dir.clone(),
                    },
                    &recreator_exe,
                    sender.clone(),
                    for_launch,
                    name,
                    effective_rename_list.as_deref(),
                )
                .map_err(|e| {
                    error!("live launch error: {e:?}");
                    format!("live launch error: {e:?}")
                })?;
                session = wrap_single_trace_as_session(handler, PathBuf::from(""))
                    .map_err(|e| -> String { format!("live session wrap error: {e:?}") })?;
                // M29 §5.2 — emit `ct/listProcesses` on live-program
                // launch. Single-entry process list whose
                // `displayName` falls back to the recording id (path
                // is empty for live recordings until the recorder
                // finishes).
                dispatch_session_load_event(&session, &sender);
                loaded_trace_folder = None;
                loaded_trace_file = None;
                loaded_raw_diff_index = None;
            }
        } else {
            // Any session whose primary trace is initialized is
            // dispatched through the session router. The router
            // delegates each request to the owning trace's
            // single-trace Handler (unchanged code path) per M24.
            let primary_initialized = session.trace(0).map(|t| t.handler.initialized).unwrap_or(false);
            if primary_initialized {
                let res = handle_request_via_session(&mut session, request.clone(), sender.clone());
                if let Err(e) = res {
                    warn!("  handle_request error in thread: {e:?}");
                    // Send an error response back to the daemon so it does not
                    // wait indefinitely for events that will never arrive
                    // (e.g., a `stopped` event after an unrecognized
                    // navigation command like `ct/goto-ticks`).
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
    }
    // Ok(())
}

#[cfg(feature = "io-transport")]
fn handle_client<W>(
    receiver: Receiver<DapMessage>,
    _receiving_thread: &thread::JoinHandle<Result<(), String>>,
    writer: W,
    cli_default_rename_list: Option<PathBuf>,
) -> Result<(), Box<dyn Error>>
where
    W: std::io::Write + Send + 'static,
{
    use log::error;

    let mut ctx = Ctx {
        cli_default_rename_list,
        ..Ctx::default()
    };

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
            if let DapMessage::Response(resp) = &msg_with_seq
                && resp.command == "disconnect"
            {
                disconnect_response_written.store(true, Ordering::SeqCst);
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
                if let Some(to_flow_sender) = ctx.to_flow_sender.clone()
                    && let Err(e) = to_flow_sender.send(request.clone())
                {
                    error!("flow send launch error: {e:?}");
                }

                if let Some(to_tracepoint_sender) = ctx.to_tracepoint_sender.clone()
                    && let Err(e) = to_tracepoint_sender.send(request.clone())
                {
                    error!("tracepoint send launch error: {e:?}");
                }
            }

            // handle all requests here: including `launch` from actually stable thread
            match request.command.as_str() {
                "ct/load-flow" => {
                    if let Some(to_flow_sender) = ctx.to_flow_sender.clone()
                        && let Err(e) = to_flow_sender.send(request.clone())
                    {
                        error!("flow send request error: {e:?}");
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
                    if let Some(to_tracepoint_sender) = ctx.to_tracepoint_sender.clone()
                        && let Err(e) = to_tracepoint_sender.send(request.clone())
                    {
                        error!("tracepoint send request error: {e:?}");
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

    /// A `.ct` container with no metadata files at all must not be
    /// classified as MCR — the helper has to be tolerant of missing
    /// metadata so callers can fall through to their normal open path
    /// without seeing spurious errors.
    #[test]
    fn is_mcr_ctfs_container_handles_no_metadata() {
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("empty.ct");

        // Provide a single placeholder file so the CTFS container is
        // valid but carries neither `meta.dat` nor `meta.json`.
        write_minimal_ctfs(&ct_path, &[("t00000000000", b"")]).unwrap();

        let mut ctfs = read_ctfs(&ct_path);
        assert!(
            !is_mcr_ctfs_container(&mut ctfs),
            "a .ct with no metadata must not classify as MCR",
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
