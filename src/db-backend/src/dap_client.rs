//! Rust client wrapper for the db-backend DAP server.
//!
//! The Debug Adapter Protocol is documented at:
//! https://microsoft.github.io/debug-adapter-protocol/

use crate::dap::{self, DapMessage};
use crate::dap_error::DapError;
use crate::dap_types;
use crate::paths::CODETRACER_PATHS;
use crate::task;
use crate::transport::DapTransport;
use serde_json::Value;
use std::collections::HashMap;
use std::env;
use std::error::Error;
use std::fmt;
use std::io::BufReader;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Child, Command};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// Client-side event categories exposed by the DAP wrapper.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CtDapEvent {
    Initialized,
    Stopped,
    Output,
    LoadedFlow,
    UpdatedTrace,
    UpdatedHistory,
    UpdatedEvents,
    UpdatedEventsContent,
    UpdatedCalltrace,
    UpdatedTable,
    CompleteMove,
    LoadedTerminal,
    Notification,
    CalltraceSearchResults,
    Unknown,
}

/// Payloads for `CtDapEvent`.
#[derive(Debug, Clone)]
pub enum CtDapEventPayload {
    Initialized,
    Stopped(dap_types::StoppedEventBody),
    Output(dap_types::OutputEventBody),
    LoadedFlow(task::FlowUpdate),
    UpdatedTrace(task::TraceUpdate),
    UpdatedHistory(task::HistoryUpdate),
    UpdatedEvents(Vec<task::ProgramEvent>),
    UpdatedEventsContent(String),
    UpdatedCalltrace(task::CallArgsUpdateResults),
    UpdatedTable(task::CtUpdatedTableResponseBody),
    CompleteMove(task::MoveState),
    LoadedTerminal(Vec<task::ProgramEvent>),
    Notification(task::Notification),
    CalltraceSearchResults(Vec<task::Call>),
    Raw(dap::Event),
}

/// Full event message delivered to callbacks.
#[derive(Debug, Clone)]
pub struct CtDapEventMessage {
    pub kind: CtDapEvent,
    pub payload: CtDapEventPayload,
}

/// Configuration for `CtBackendDapWrapper`.
///
/// The default `server_path` resolves from `CODETRACER_DB_BACKEND_BIN` or falls back to `db-backend`.
#[derive(Debug, Clone)]
pub struct CtBackendDapConfig {
    /// Path to the db-backend executable.
    pub server_path: PathBuf,
    /// Optional socket path override.
    pub socket_path: Option<PathBuf>,
    /// Timeout for request/response round-trips.
    pub response_timeout: Duration,
    /// Retry count for connecting to the DAP socket.
    pub connect_retries: usize,
    /// Delay between connection retries.
    pub connect_retry_delay: Duration,
}

impl Default for CtBackendDapConfig {
    fn default() -> Self {
        let server_path = env::var_os("CODETRACER_DB_BACKEND_BIN")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("db-backend"));
        Self {
            server_path,
            socket_path: None,
            response_timeout: Duration::from_secs(30),
            connect_retries: 50,
            connect_retry_delay: Duration::from_millis(50),
        }
    }
}

/// Errors produced by the DAP wrapper.
#[derive(Debug)]
pub enum CtBackendDapError {
    Io(std::io::Error),
    Json(serde_json::Error),
    Protocol(String),
    Timeout { command: String, seq: i64 },
    ChannelClosed(String),
    PoisonedLock(&'static str),
    Spawn(String),
}

impl fmt::Display for CtBackendDapError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CtBackendDapError::Io(err) => write!(f, "io error: {err}"),
            CtBackendDapError::Json(err) => write!(f, "json error: {err}"),
            CtBackendDapError::Protocol(msg) => write!(f, "protocol error: {msg}"),
            CtBackendDapError::Timeout { command, seq } => {
                write!(f, "timeout waiting for response to {command} (seq {seq})")
            }
            CtBackendDapError::ChannelClosed(msg) => write!(f, "channel closed: {msg}"),
            CtBackendDapError::PoisonedLock(name) => write!(f, "poisoned lock: {name}"),
            CtBackendDapError::Spawn(msg) => write!(f, "spawn error: {msg}"),
        }
    }
}

impl Error for CtBackendDapError {}

impl From<std::io::Error> for CtBackendDapError {
    fn from(err: std::io::Error) -> Self {
        CtBackendDapError::Io(err)
    }
}

impl From<serde_json::Error> for CtBackendDapError {
    fn from(err: serde_json::Error) -> Self {
        CtBackendDapError::Json(err)
    }
}

impl From<DapError> for CtBackendDapError {
    fn from(err: DapError) -> Self {
        match err {
            DapError::Io(inner) => CtBackendDapError::Io(inner),
            DapError::Json(inner) => CtBackendDapError::Json(inner),
            #[cfg(feature = "browser-transport")]
            DapError::SerdeWasm(inner) => CtBackendDapError::Protocol(inner.to_string()),
            #[cfg(feature = "browser-transport")]
            DapError::Js(inner) => CtBackendDapError::Protocol(inner.to_string()),
            DapError::Msg(message) => CtBackendDapError::Protocol(message),
        }
    }
}

type CtBackendResult<T> = Result<T, CtBackendDapError>;
type EventHandler = Arc<dyn Fn(CtDapEventMessage) + Send + Sync + 'static>;

/// Thin DAP client that spawns db-backend and dispatches its events.
///
/// ```no_run
/// use db_backend::dap_client::{CtBackendDapWrapper, CtDapEvent, CtLaunchOptions};
/// use db_backend::dap_types::InitializeRequestArguments;
/// use db_backend::task::{CtLoadFlowArguments, CtLoadLocalsArguments, FlowMode, Location};
///
/// let trace_path = std::path::PathBuf::from("/tmp/trace");
/// let ct_backend = CtBackendDapWrapper::new().expect("dap start");
///
/// let init_args = InitializeRequestArguments {
///     adapter_id: "codetracer".to_string(),
///     ..Default::default()
/// };
/// ct_backend.initialize(init_args).expect("initialize");
/// ct_backend
///     .launch(trace_path, CtLaunchOptions::default())
///     .expect("launch");
///
/// let locals_args = CtLoadLocalsArguments::default();
/// let _locals = ct_backend.load_locals(locals_args).expect("locals");
///
/// let flow_args = CtLoadFlowArguments {
///     flow_mode: FlowMode::Call,
///     location: Location::default(),
/// };
/// ct_backend.load_flow(flow_args).expect("flow");
/// ct_backend
///     .on(CtDapEvent::LoadedFlow, |event| {
///         println!("event {event:?}");
///     })
///     .expect("subscribe");
/// ```
pub struct CtBackendDapWrapper {
    child: Mutex<Option<Child>>,
    writer: Mutex<UnixStream>,
    seq: AtomicI64,
    pending: Arc<Mutex<HashMap<i64, mpsc::Sender<dap::Response>>>>,
    handlers: Arc<Mutex<HashMap<CtDapEvent, Vec<EventHandler>>>>,
    last_events: Arc<Mutex<HashMap<CtDapEvent, CtDapEventMessage>>>,
    response_timeout: Duration,
    _reader_thread: JoinHandle<()>,
}

impl CtBackendDapWrapper {
    /// Spawn db-backend with default configuration and connect over DAP.
    pub fn new() -> CtBackendResult<Self> {
        Self::with_config(CtBackendDapConfig::default())
    }

    /// Spawn db-backend with a custom configuration and connect over DAP.
    pub fn with_config(config: CtBackendDapConfig) -> CtBackendResult<Self> {
        let socket_path = if let Some(path) = config.socket_path.clone() {
            path
        } else {
            default_socket_path()?
        };
        let _ = std::fs::remove_file(&socket_path);

        let child = Command::new(&config.server_path)
            .arg("dap-server")
            .arg(&socket_path)
            .spawn()
            .map_err(|err| CtBackendDapError::Spawn(format!("{err}")))?;

        let stream = connect_with_retries(
            &socket_path,
            config.connect_retries,
            config.connect_retry_delay,
        )?;

        let reader_stream = stream.try_clone()?;

        let pending = Arc::new(Mutex::new(HashMap::new()));
        let handlers = Arc::new(Mutex::new(HashMap::new()));
        let last_events = Arc::new(Mutex::new(HashMap::new()));

        let reader_thread = spawn_reader_thread(reader_stream, pending.clone(), handlers.clone(), last_events.clone());

        Ok(Self {
            child: Mutex::new(Some(child)),
            writer: Mutex::new(stream),
            seq: AtomicI64::new(1),
            pending,
            handlers,
            last_events,
            response_timeout: config.response_timeout,
            _reader_thread: reader_thread,
        })
    }

    /// Register a callback for a DAP event type.
    ///
    /// If the event already occurred, the latest cached event is delivered immediately.
    pub fn on<F>(&self, event: CtDapEvent, handler: F) -> CtBackendResult<()>
    where
        F: Fn(CtDapEventMessage) + Send + Sync + 'static,
    {
        let handler = Arc::new(handler);
        {
            let mut handlers = lock_mutex(&self.handlers, "handlers")?;
            handlers.entry(event).or_default().push(handler.clone());
        }
        // Deliver the most recent event so late subscribers still see stateful updates.
        if let Some(last_event) = {
            let events = lock_mutex(&self.last_events, "last_events")?;
            events.get(&event).cloned()
        } {
            handler(last_event);
        }
        Ok(())
    }

    /// Send the DAP initialize request.
    pub fn initialize(&self, args: dap_types::InitializeRequestArguments) -> CtBackendResult<()> {
        let mut args = args;
        if args.adapter_id.is_empty() {
            args.adapter_id = "codetracer".to_string();
        }
        let response = self.request_response("initialize", serde_json::to_value(args)?)?;
        ensure_success("initialize", &response)
    }

    /// Send the DAP launch request using a trace folder.
    pub fn launch<P: Into<PathBuf>>(
        &self,
        trace_folder: P,
        options: CtLaunchOptions,
    ) -> CtBackendResult<()> {
        let args = options.to_launch_args(trace_folder.into());
        let response = self.request_response("launch", serde_json::to_value(args)?)?;
        ensure_success("launch", &response)
    }

    /// Send `ct/load-locals` and return the locals response.
    pub fn load_locals(
        &self,
        args: task::CtLoadLocalsArguments,
    ) -> CtBackendResult<task::CtLoadLocalsResponseBody> {
        let response = self.request_response("ct/load-locals", serde_json::to_value(args)?)?;
        ensure_success("ct/load-locals", &response)?;
        let body = serde_json::from_value::<task::CtLoadLocalsResponseBody>(response.body)?;
        Ok(body)
    }

    /// Send `ct/load-flow`. The resulting flow arrives via the `ct/updated-flow` event.
    pub fn load_flow(&self, args: task::CtLoadFlowArguments) -> CtBackendResult<()> {
        self.send_request("ct/load-flow", serde_json::to_value(args)?)?;
        Ok(())
    }

    /// Send the DAP disconnect request and wait for acknowledgement.
    pub fn disconnect(&self) -> CtBackendResult<()> {
        let response = self.request_response("disconnect", Value::Object(serde_json::Map::new()))?;
        ensure_success("disconnect", &response)
    }

    fn next_seq(&self) -> i64 {
        self.seq.fetch_add(1, Ordering::SeqCst)
    }

    fn send_request(&self, command: &str, arguments: Value) -> CtBackendResult<i64> {
        let seq = self.next_seq();
        let request = DapMessage::Request(dap::Request {
            base: dap::ProtocolMessage {
                seq,
                type_: "request".to_string(),
            },
            command: command.to_string(),
            arguments,
        });
        self.send_message(&request)?;
        Ok(seq)
    }

    fn request_response(&self, command: &str, arguments: Value) -> CtBackendResult<dap::Response> {
        let seq = self.next_seq();
        let (tx, rx) = mpsc::channel();
        {
            let mut pending = lock_mutex(&self.pending, "pending")?;
            // Pair request seq with a one-shot channel so the reader thread can resolve it.
            pending.insert(seq, tx);
        }
        let request = DapMessage::Request(dap::Request {
            base: dap::ProtocolMessage {
                seq,
                type_: "request".to_string(),
            },
            command: command.to_string(),
            arguments,
        });
        if let Err(err) = self.send_message(&request) {
            let mut pending = lock_mutex(&self.pending, "pending")?;
            pending.remove(&seq);
            return Err(err);
        }
        match rx.recv_timeout(self.response_timeout) {
            Ok(response) => Ok(response),
            Err(mpsc::RecvTimeoutError::Timeout) => {
                let mut pending = lock_mutex(&self.pending, "pending")?;
                pending.remove(&seq);
                Err(CtBackendDapError::Timeout {
                    command: command.to_string(),
                    seq,
                })
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => Err(CtBackendDapError::ChannelClosed(
                "response channel disconnected".to_string(),
            )),
        }
    }

    fn send_message(&self, message: &DapMessage) -> CtBackendResult<()> {
        let mut writer = lock_mutex(&self.writer, "writer")?;
        writer.send(message).map_err(CtBackendDapError::from)
    }
}

impl Drop for CtBackendDapWrapper {
    fn drop(&mut self) {
        let _ = self.send_request("disconnect", Value::Object(serde_json::Map::new()));
        if let Ok(mut child_guard) = self.child.lock() {
            if let Some(mut child) = child_guard.take() {
                let _ = child.kill();
                let _ = child.wait();
            }
        }
    }
}

/// Convenience launch options for trace-folder based sessions.
#[derive(Debug, Clone, Default)]
pub struct CtLaunchOptions {
    /// Optional program path (used mainly for display).
    pub program: Option<String>,
    /// Optional trace file name inside the trace folder.
    pub trace_file: Option<PathBuf>,
    /// Optional raw diff index payload for diff flow mode.
    pub raw_diff_index: Option<String>,
    /// Optional rr worker executable for replay-based traces.
    pub ct_rr_worker_exe: Option<PathBuf>,
    /// Restore location to re-open the trace at a prior UI position.
    pub restore_location: Option<task::Location>,
    /// Optional process id for attach-like flows.
    pub pid: Option<u64>,
    /// Optional working directory to resolve relative paths.
    pub cwd: Option<String>,
    /// DAP-standard noDebug flag for tooling integrations.
    pub no_debug: Option<bool>,
    /// Optional human-readable session name.
    pub name: Option<String>,
    /// Optional DAP request name.
    pub request: Option<String>,
    /// Optional DAP adapter type.
    pub typ: Option<String>,
    /// Optional session id for editor integrations.
    pub session_id: Option<String>,
}

impl CtLaunchOptions {
    fn to_launch_args(self, trace_folder: PathBuf) -> dap::LaunchRequestArguments {
        dap::LaunchRequestArguments {
            program: self.program,
            trace_folder: Some(trace_folder),
            trace_file: self.trace_file,
            raw_diff_index: self.raw_diff_index,
            ct_rr_worker_exe: self.ct_rr_worker_exe,
            restore_location: self.restore_location,
            pid: self.pid,
            cwd: self.cwd,
            no_debug: self.no_debug,
            restart: None,
            name: self.name,
            request: self.request,
            typ: self.typ,
            session_id: self.session_id,
        }
    }
}

fn ensure_success(command: &str, response: &dap::Response) -> CtBackendResult<()> {
    if response.command != command {
        return Err(CtBackendDapError::Protocol(format!(
            "response command mismatch: expected {command}, got {}",
            response.command
        )));
    }
    if response.success {
        Ok(())
    } else {
        Err(CtBackendDapError::Protocol(format!(
            "request {command} failed: {:?}",
            response.message
        )))
    }
}

fn default_socket_path() -> CtBackendResult<PathBuf> {
    let tmp_path = { CODETRACER_PATHS.lock().map_err(|_| CtBackendDapError::PoisonedLock("paths"))?.tmp_path.clone() };
    let pid = std::process::id();
    // Add a monotonic-ish nonce to avoid socket collisions in long-lived processes.
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|err| CtBackendDapError::Protocol(format!("system time error: {err}")))?
        .as_nanos();
    Ok(tmp_path.join(format!("ct_dap_socket_{pid}_{nonce}.sock")))
}

fn connect_with_retries(
    socket_path: &PathBuf,
    retries: usize,
    delay: Duration,
) -> CtBackendResult<UnixStream> {
    for attempt in 0..=retries {
        match UnixStream::connect(socket_path) {
            Ok(stream) => return Ok(stream),
            Err(_err) if attempt < retries => {
                std::thread::sleep(delay);
                continue;
            }
            Err(err) => return Err(CtBackendDapError::Io(err)),
        }
    }
    Err(CtBackendDapError::Protocol(
        "exhausted socket connection retries".to_string(),
    ))
}

fn spawn_reader_thread(
    stream: UnixStream,
    pending: Arc<Mutex<HashMap<i64, mpsc::Sender<dap::Response>>>>,
    handlers: Arc<Mutex<HashMap<CtDapEvent, Vec<EventHandler>>>>,
    last_events: Arc<Mutex<HashMap<CtDapEvent, CtDapEventMessage>>>,
) -> JoinHandle<()> {
    thread::spawn(move || {
        let mut reader = BufReader::new(stream);
        loop {
            match dap::read_dap_message_from_reader(&mut reader) {
                Ok(DapMessage::Response(response)) => {
                    if let Ok(mut pending) = pending.lock() {
                        if let Some(tx) = pending.remove(&response.request_seq) {
                            let _ = tx.send(response);
                        }
                    }
                }
                Ok(DapMessage::Event(event)) => {
                    let message = match map_event(event) {
                        Ok(event) => event,
                        Err(err) => {
                            log::error!("DAP event decode failed: {err}");
                            continue;
                        }
                    };
                    if let Ok(mut cache) = last_events.lock() {
                        cache.insert(message.kind, message.clone());
                    }
                    // Clone handlers so callbacks can run without holding the lock.
                    let callbacks = if let Ok(handlers) = handlers.lock() {
                        handlers.get(&message.kind).cloned().unwrap_or_default()
                    } else {
                        Vec::new()
                    };
                    for handler in callbacks {
                        handler(message.clone());
                    }
                }
                Ok(_) => {}
                Err(err) => {
                    log::error!("DAP read failed: {err}");
                    break;
                }
            }
        }
    })
}

fn map_event(event: dap::Event) -> CtBackendResult<CtDapEventMessage> {
    let (kind, payload) = match event.event.as_str() {
        "initialized" => (CtDapEvent::Initialized, CtDapEventPayload::Initialized),
        "stopped" => (
            CtDapEvent::Stopped,
            CtDapEventPayload::Stopped(serde_json::from_value(event.body.clone())?),
        ),
        "output" => (
            CtDapEvent::Output,
            CtDapEventPayload::Output(serde_json::from_value(event.body.clone())?),
        ),
        "ct/updated-flow" => (
            CtDapEvent::LoadedFlow,
            CtDapEventPayload::LoadedFlow(serde_json::from_value(event.body.clone())?),
        ),
        "ct/updated-trace" => (
            CtDapEvent::UpdatedTrace,
            CtDapEventPayload::UpdatedTrace(serde_json::from_value(event.body.clone())?),
        ),
        "ct/updated-history" => (
            CtDapEvent::UpdatedHistory,
            CtDapEventPayload::UpdatedHistory(serde_json::from_value(event.body.clone())?),
        ),
        "ct/updated-events" => (
            CtDapEvent::UpdatedEvents,
            CtDapEventPayload::UpdatedEvents(serde_json::from_value(event.body.clone())?),
        ),
        "ct/updated-events-content" => (
            CtDapEvent::UpdatedEventsContent,
            CtDapEventPayload::UpdatedEventsContent(serde_json::from_value(event.body.clone())?),
        ),
        "ct/updated-calltrace" => (
            CtDapEvent::UpdatedCalltrace,
            CtDapEventPayload::UpdatedCalltrace(serde_json::from_value(event.body.clone())?),
        ),
        "ct/updated-table" => (
            CtDapEvent::UpdatedTable,
            CtDapEventPayload::UpdatedTable(serde_json::from_value(event.body.clone())?),
        ),
        "ct/complete-move" => (
            CtDapEvent::CompleteMove,
            CtDapEventPayload::CompleteMove(serde_json::from_value(event.body.clone())?),
        ),
        "ct/loaded-terminal" => (
            CtDapEvent::LoadedTerminal,
            CtDapEventPayload::LoadedTerminal(serde_json::from_value(event.body.clone())?),
        ),
        "ct/notification" => (
            CtDapEvent::Notification,
            CtDapEventPayload::Notification(serde_json::from_value(event.body.clone())?),
        ),
        "ct/calltrace-search-res" => (
            CtDapEvent::CalltraceSearchResults,
            CtDapEventPayload::CalltraceSearchResults(serde_json::from_value(event.body.clone())?),
        ),
        _ => (CtDapEvent::Unknown, CtDapEventPayload::Raw(event)),
    };
    Ok(CtDapEventMessage { kind, payload })
}

fn lock_mutex<T>(mutex: &Mutex<T>, name: &'static str) -> CtBackendResult<std::sync::MutexGuard<'_, T>> {
    mutex.lock().map_err(|_| CtBackendDapError::PoisonedLock(name))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn map_event_handles_flow_update() {
        let flow_update = task::FlowUpdate::new();
        let event = dap::Event {
            base: dap::ProtocolMessage {
                seq: 1,
                type_: "event".to_string(),
            },
            event: "ct/updated-flow".to_string(),
            body: serde_json::to_value(flow_update.clone()).expect("serialize flow update"),
        };

        let message = map_event(event).expect("map event");
        assert_eq!(message.kind, CtDapEvent::LoadedFlow);
        match message.payload {
            CtDapEventPayload::LoadedFlow(payload) => assert_eq!(payload.location, flow_update.location),
            _ => panic!("unexpected payload"),
        }
    }

    #[test]
    fn map_event_handles_initialized() {
        let event = dap::Event {
            base: dap::ProtocolMessage {
                seq: 2,
                type_: "event".to_string(),
            },
            event: "initialized".to_string(),
            body: serde_json::to_value(serde_json::Map::<String, Value>::new())
                .expect("serialize initialized body"),
        };

        let message = map_event(event).expect("map initialized");
        assert_eq!(message.kind, CtDapEvent::Initialized);
        match message.payload {
            CtDapEventPayload::Initialized => {}
            _ => panic!("unexpected payload"),
        }
    }

    #[test]
    fn map_event_handles_unknown() {
        let event = dap::Event {
            base: dap::ProtocolMessage {
                seq: 3,
                type_: "event".to_string(),
            },
            event: "ct/unknown-event".to_string(),
            body: serde_json::to_value(serde_json::Map::<String, Value>::new())
                .expect("serialize unknown body"),
        };

        let message = map_event(event).expect("map unknown");
        assert_eq!(message.kind, CtDapEvent::Unknown);
        match message.payload {
            CtDapEventPayload::Raw(raw) => assert_eq!(raw.event, "ct/unknown-event"),
            _ => panic!("unexpected payload"),
        }
    }
}
