#[cfg(all(test, unix))]
#[path = "../tests/support/mcp_harness.rs"]
mod request_cleanup_harness;

#[cfg(windows)]
#[allow(unused_imports)]
use std::os::windows::process::CommandExt;
use std::{
    collections::HashMap, error::Error, fmt::Debug, path::PathBuf, sync::Arc, time::Duration,
};

/// Windows `CREATE_NO_WINDOW` flag — prevents console apps from creating
/// a visible console window when spawned as child processes.
#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x08000000;

use futures_util::FutureExt;
use serde_json::{Value, json};
#[cfg(unix)]
use tokio::fs::remove_file;
#[cfg(windows)]
use tokio::net::{TcpListener, TcpStream};
#[cfg(unix)]
use tokio::net::{UnixListener, UnixStream};
use tokio::{
    fs::create_dir_all,
    io::{AsyncReadExt, AsyncWriteExt, WriteHalf},
    process::{Child, Command},
    sync::{
        Mutex,
        mpsc::{self, UnboundedReceiver, UnboundedSender},
    },
    time::sleep,
};

#[cfg(unix)]
use crate::errors::{SocketPathError, SocketPathTooLong};
use crate::{
    config::DaemonConfig,
    dap_init,
    dap_parser::DapParser,
    errors::InvalidID,
    paths::CODETRACER_PATHS,
    python_bridge::{
        self, PendingPyNavState, PendingPyRequest, PendingPyRequestKind, PyBridgeState,
    },
    script_executor,
    session::{HostSourceReads, SessionKey, SessionManager},
    trace_metadata,
};

/// The `lang` this process puts on a `ct/load-locals` request when its client
/// did not say: the `Lang::wire_name` of `Lang::C`, spelled as a literal.
///
/// A NAME, never an ordinal (LRS-1).  The db-backend decodes the field with
/// `ct-lang`'s `lang_wire` adapter and refuses a bare integer, and `"c"` is
/// what the integer `0` this process used to send decoded to (`Lang::default()`).
///
/// A literal rather than `ct_lang::Lang::C.wire_name()` because this crate
/// must stay free of path dependencies: the `backend-manager` nix derivation
/// (`nix/packages/default.nix`) takes the CRATE directory as its source, not
/// the repository, so `../../libs/ct-lang` does not exist in its sandbox and
/// `nix build .#codetracer` would fail to resolve the manifest.  The literal
/// is pinned against the production table by
/// `src/tests/cli/lang_enum_contract_test.nim` (property 7, "the
/// backend-manager's literal default is langWireName(LangC)"), so it cannot
/// drift silently; if it ever did, the request would be REFUSED and named,
/// not decoded as a different language.
const LOAD_LOCALS_DEFAULT_LANG: &str = "c";

/// The field the single-client forwarder adds to every message a replay
/// sends, naming that replay (the id `ct/start-replay` answered with).
///
/// The forwarder multiplexes every replay onto ONE frontend connection, and a
/// DAP event carries nothing that says which replay emitted it: the frontend
/// had to assume "the replay last selected", which is wrong whenever two
/// replays run at once — an event of one replay that arrives after a request
/// for the other was attributed to the other. `ct host` gives every connected
/// client its own replay (`CLI/ct/host.md`, "Sessions are isolated"), so an
/// event attributed to the wrong replay is shown to the wrong client. The tag
/// names the source exactly; a frontend that does not read it is unaffected,
/// since DAP consumers ignore fields they do not know.
pub const REPLAY_ID_TAG: &str = "ctReplayId";

/// `message` with [`REPLAY_ID_TAG`] set to `replay_id` when it is a JSON
/// object (every DAP message is); anything else is passed through untouched.
fn tag_with_replay_id(mut message: Value, replay_id: usize) -> Value {
    if let Some(object) = message.as_object_mut() {
        object.insert(REPLAY_ID_TAG.to_string(), json!(replay_id));
    }
    message
}

/// Write handle for a single connected daemon client, together with its
/// unique identifier.  Used by the daemon-mode response router.
/// What sends DAP messages to one daemon client: its channel, and the table
/// that maps the daemon's numbering of the client's requests back to the
/// client's own.
///
/// Every client numbers its requests itself, from 1, so two clients' `seq`
/// values collide.  The daemon gives each request a `seq` of its own, unique
/// across clients, before dispatching it (`dispatch_client_message`), routes
/// the answer by that number, and [`ClientSender::send`] writes the client's
/// own number back into the answer.  A client cannot reach another client's
/// answer by reusing its `seq`.
#[derive(Clone)]
struct ClientSender {
    tx: UnboundedSender<Value>,
    seqs: Arc<std::sync::Mutex<HashMap<i64, i64>>>,
}

impl ClientSender {
    fn new(tx: UnboundedSender<Value>) -> Self {
        Self {
            tx,
            seqs: Arc::new(std::sync::Mutex::new(HashMap::new())),
        }
    }

    /// Record that the daemon's request `daemon_seq` is this client's `own_seq`.
    fn number(&self, daemon_seq: i64, own_seq: i64) {
        self.seqs
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(daemon_seq, own_seq);
    }

    /// Send `message`; an answer to one of this client's requests carries
    /// the client's own `seq` again.
    fn send(&self, mut message: Value) -> Result<(), mpsc::error::SendError<Value>> {
        if message.get("type").and_then(Value::as_str) == Some("response")
            && let Some(daemon_seq) = message.get("request_seq").and_then(Value::as_i64)
            && let Some(own_seq) = self
                .seqs
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .remove(&daemon_seq)
        {
            message["request_seq"] = json!(own_seq);
        }
        self.tx.send(message)
    }
}

/// The first `seq` the daemon gives a client's request: above the Python
/// bridge's own numbers (`PyBridgeState::next_seq`, from 1,000,000), and
/// within a 32-bit integer for backends that read `seq` as one.
const DAEMON_SEQ_BASE: i64 = 2_000_000_000;

struct ClientHandle {
    /// Sends DAP messages back to this client.
    sender: ClientSender,
    /// For the connection a confined script inherits, what it may ask for
    /// ([`ScriptGrant`]); `None` for a client that connected to the socket.
    script: Option<ScriptGrant>,
}

/// What the connection handed to one confined `exec_script` run may ask the
/// daemon for: the queries of that run's trace, in the session its client
/// asked for, and nothing else.
///
/// The script runs arbitrary Python and may open no socket
/// (`crate::script_confinement`), so this connection is its only way to the
/// daemon, and the daemon is not confined: a request that starts a process
/// (`ct/start-replay` names the program it runs), runs another script, opens
/// another trace or stops the daemon would let the script act with the
/// daemon's privileges.  [`ScriptGrant::admit`] refuses every such request.
#[derive(Debug, Clone)]
struct ScriptGrant {
    /// The run's trace, canonicalized.
    trace_path: PathBuf,
    /// The host-read setting of the client that asked for the run; every
    /// admitted request is sent with it, whatever the script wrote.
    host_source_reads: HostSourceReads,
}

impl ScriptGrant {
    /// The commands a script's queries are made of: the Python API's
    /// (`python-api/codetracer`), each naming the run's trace.
    fn admits_command(command: &str) -> bool {
        command == "ct/open-trace" || command == "ct/close-trace" || command.starts_with("ct/py-")
    }

    /// `message` as it is dispatched (its `hostSourceReads` set to the
    /// grant's), or why it is refused.
    fn admit(&self, mut message: Value) -> Result<Value, String> {
        let is_request = message.get("type").and_then(Value::as_str) == Some("request");
        let command = message
            .get("command")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        if !is_request || !Self::admits_command(&command) {
            return Err(format!(
                "a script may ask only for queries of its own trace; `{command}` is refused"
            ));
        }
        let Some(arguments) = message.get_mut("arguments").and_then(Value::as_object_mut) else {
            return Err(format!("`{command}` names no trace"));
        };
        let mut named = 0;
        for key in ["tracePath", "recordTrace"] {
            if let Some(value) = arguments.get(key).cloned() {
                let Some(path) = value.as_str() else {
                    return Err(format!("`{command}`: {key} is not a path"));
                };
                if canonical_trace_path(path) != self.trace_path {
                    return Err(format!(
                        "a script may query only its own trace; `{command}` names another"
                    ));
                }
                // Dispatched under the granted path itself, not the name the
                // script wrote: a name is resolved again by everything that
                // opens it, so a symlink the script swaps after this check
                // would otherwise open another recording.
                let granted = self
                    .trace_path
                    .to_str()
                    .ok_or_else(|| format!("`{command}`: the granted trace path is not UTF-8"))?;
                arguments.insert(key.to_string(), Value::String(granted.to_string()));
                named += 1;
            }
        }
        if named == 0 {
            return Err(format!("`{command}` names no trace"));
        }
        if arguments.contains_key("tracePath") {
            arguments.insert(
                "hostSourceReads".to_string(),
                Value::Bool(self.host_source_reads.is_allowed()),
            );
        }
        Ok(message)
    }
}

/// A trace path as the script grant compares it: canonical when it exists,
/// as given otherwise.
fn canonical_trace_path(path: &str) -> PathBuf {
    std::fs::canonicalize(path).unwrap_or_else(|_| PathBuf::from(path))
}

/// The text of a panic payload, for the log and the client's answer.
fn panic_text(payload: &(dyn std::any::Any + Send)) -> String {
    if let Some(text) = payload.downcast_ref::<&str>() {
        (*text).to_string()
    } else if let Some(text) = payload.downcast_ref::<String>() {
        text.clone()
    } else {
        "a panic with no message".to_string()
    }
}

/// Shared mutable state that the daemon accept loop and response router need.
///
/// Separated from `BackendManager` so that legacy (single-client) mode does
/// not pay for daemon bookkeeping.
pub struct DaemonState {
    /// Connected clients keyed by their auto-incremented ID.
    clients: HashMap<u64, ClientHandle>,
    /// Maps a DAP request `seq` number to the client ID that sent the request.
    /// When a response arrives for a given `seq`, the daemon routes it back to
    /// the originating client and removes the entry.
    request_client_map: HashMap<i64, u64>,
    /// Sender half of the channel used to request a clean daemon shutdown.
    shutdown_tx: Option<UnboundedSender<()>>,
    /// Per-trace session manager with TTL tracking.
    session_manager: SessionManager,
    /// Configuration snapshot taken at daemon startup.
    config: DaemonConfig,
    /// State for Python bridge navigation operations (ct/py-navigate).
    py_bridge: PyBridgeState,
    /// The dispatch loop's inbound channel and the next client id, shared
    /// with the accept loop, so a connection the daemon makes itself (a
    /// confined script's, [`ScriptGrant`]) is read like an accepted one.
    inbound_tx: Option<UnboundedSender<(u64, Value)>>,
    next_client_id: Arc<std::sync::atomic::AtomicU64>,
    /// The next `seq` the daemon gives a client's request ([`ClientSender`]).
    next_daemon_seq: i64,
    /// The manager itself, for tasks spawned from a handler.
    self_ref: std::sync::Weak<Mutex<BackendManager>>,
}

impl Debug for DaemonState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DaemonState")
            .field("num_clients", &self.clients.len())
            .field("pending_requests", &self.request_client_map.len())
            .field("session_manager", &self.session_manager)
            .finish()
    }
}

#[derive(Debug)]
pub struct BackendManager {
    children: Vec<Option<Child>>,
    children_receivers: Vec<Option<UnboundedReceiver<Value>>>,
    parent_senders: Vec<Option<UnboundedSender<Value>>>,
    selected: usize,
    manager_receiver: Option<UnboundedReceiver<Value>>,
    manager_sender: Option<UnboundedSender<Value>>,
    /// Present only in daemon mode.  `None` for legacy single-client mode.
    daemon_state: Option<DaemonState>,
}

/// Check whether `path` is a file whose first 5 bytes match the CTFS magic
/// number (`0xC0 0xDE 0x72 0xAC 0xE2`).  Returns `false` for directories,
/// missing files, or files shorter than 5 bytes.
fn has_ctfs_magic(path: &std::path::Path) -> bool {
    if !path.is_file() {
        return false;
    }
    let Ok(mut f) = std::fs::File::open(path) else {
        return false;
    };
    let mut magic = [0u8; 5];
    use std::io::Read;
    f.read_exact(&mut magic).is_ok() && magic == [0xC0, 0xDE, 0x72, 0xAC, 0xE2]
}

/// The longest path, in bytes, a Unix socket address holds: the size of
/// `sockaddr_un.sun_path` less its terminating NUL (unix(7)).
#[cfg(unix)]
pub(crate) const MAX_UNIX_SOCKET_PATH: usize = std::mem::size_of::<libc::sockaddr_un>()
    - std::mem::offset_of!(libc::sockaddr_un, sun_path)
    - 1;

/// `path` if a Unix socket can be bound there, else [`SocketPathTooLong`]
/// naming it: `bind(2)` would refuse it with an error that names neither the
/// path nor the limit.
#[cfg(unix)]
pub(crate) fn check_unix_socket_path(path: &std::path::Path) -> Result<(), SocketPathTooLong> {
    use std::os::unix::ffi::OsStrExt;
    let len = path.as_os_str().as_bytes().len();
    if len > MAX_UNIX_SOCKET_PATH {
        return Err(SocketPathTooLong {
            path: path.to_path_buf(),
            len,
            max: MAX_UNIX_SOCKET_PATH,
        });
    }
    Ok(())
}

/// Bind a Unix socket listener at `path`, refusing a path too long for a
/// socket address by name ([`check_unix_socket_path`]).  Every listener the
/// session manager binds (the daemon's socket, a replay backend's socket)
/// goes through here.
#[cfg(unix)]
fn bind_unix_listener(path: &std::path::Path) -> Result<UnixListener, Box<dyn Error>> {
    check_unix_socket_path(path)?;
    Ok(UnixListener::bind(path)?)
}

/// Make the daemon socket at `path` readable and writable by its owner only.
#[cfg(unix)]
fn restrict_socket_to_owner(path: &std::path::Path) -> Result<(), Box<dyn Error>> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).map_err(|e| {
        format!(
            "cannot restrict the daemon socket {} to its owner: {e}",
            path.display()
        )
    })?;
    Ok(())
}

/// Accept a connection only from a process of the user this process runs
/// as (its effective user id), by the peer credentials the kernel records
/// for the socket (`SO_PEERCRED`, `getpeereid`).  The socket's mode is the
/// first check; this one holds when the mode does not (a socket path in a
/// shared directory, a mode changed after the bind).
#[cfg(unix)]
pub(crate) fn check_peer_is_this_user(socket: &UnixStream) -> Result<(), String> {
    let cred = socket
        .peer_cred()
        .map_err(|e| format!("its peer credentials cannot be read: {e}"))?;
    // SAFETY: geteuid has no preconditions and cannot fail.
    let me = unsafe { libc::geteuid() };
    if cred.uid() != me {
        return Err(format!(
            "its peer runs as uid {} and this process as uid {me}",
            cred.uid()
        ));
    }
    Ok(())
}

/// `accept`, the replay's connection to the endpoint it was told to connect
/// to (`endpoint`: a Unix socket path, or a `host:port` on Windows), unless the replay process `child` (started as
/// `command`) exits first: then an error saying so, with its exit status.
///
/// A replay that dies before it connects (it cannot parse its arguments, a
/// library it needs is missing) would otherwise leave `accept` waiting for
/// ever, and it is awaited with the manager's lock held, so the session
/// manager answered nothing more at all — not the `ct/start-replay`, not a
/// `ct/ping`.
async fn accept_unless_exited<T>(
    child: &mut tokio::process::Child,
    accept: impl std::future::Future<Output = std::io::Result<T>>,
    command: &str,
    endpoint: &(dyn std::fmt::Display + Sync),
) -> Result<std::io::Result<T>, Box<dyn Error>> {
    tokio::select! {
        accepted = accept => Ok(accepted),
        status = child.wait() => {
            let status = match status {
                Ok(status) => status.to_string(),
                Err(err) => format!("its status could not be read: {err}"),
            };
            Err(format!(
                "the replay process `{command}` exited ({status}) before it connected to {endpoint}"
            )
            .into())
        }
    }
}

// TODO: cleanup on exit
// TODO: Handle signals
impl BackendManager {
    // -----------------------------------------------------------------------
    // Legacy single-client constructor — UNCHANGED from the original code.
    // -----------------------------------------------------------------------

    #[cfg(unix)]
    pub async fn new() -> Result<Arc<Mutex<Self>>, Box<dyn Error>> {
        let res = Arc::new(Mutex::new(Self {
            children: vec![],
            children_receivers: vec![],
            parent_senders: vec![],
            selected: 0,
            manager_receiver: None,
            manager_sender: None,
            daemon_state: None,
        }));

        let res1 = res.clone();
        let res2 = res.clone();

        let socket_dir: std::path::PathBuf;
        {
            let path = &CODETRACER_PATHS.lock()?;
            socket_dir = path.tmp_path.join("session-manager");
        }

        create_dir_all(&socket_dir).await?;

        let socket_path = socket_dir.join(std::process::id().to_string() + ".sock");
        _ = remove_file(&socket_path).await;

        let mut socket_read;
        let mut socket_write;

        info!("Socket listening on: {}", socket_path.display());

        let listener = bind_unix_listener(&socket_path)?;
        match listener.accept().await {
            Ok((socket, _addr)) => (socket_read, socket_write) = tokio::io::split(socket),
            Err(err) => return Err(Box::new(err)),
        }

        info!("Connected");

        let (manager_tx, manager_rx) = mpsc::unbounded_channel::<Value>();
        {
            let mut locked = res.lock().await;
            locked.manager_receiver = Some(manager_rx);
            locked.manager_sender = Some(manager_tx);
        }

        tokio::spawn(async move {
            loop {
                sleep(Duration::from_millis(10)).await;

                let mut res = res2.lock().await;
                for (replay_id, rx_opt) in res.children_receivers.iter_mut().enumerate() {
                    let Some(rx) = rx_opt else { continue };
                    if !rx.is_empty()
                        && let Some(message) = rx.recv().await
                    {
                        let message = tag_with_replay_id(message, replay_id);
                        let write_res =
                            socket_write.write_all(&DapParser::to_bytes(&message)).await;

                        match write_res {
                            Ok(()) => {}
                            Err(err) => {
                                error!("Can't write to frontend socket! Error: {err}");
                            }
                        }
                    }
                }

                #[allow(clippy::collapsible_if)]
                // alexander: i think it's ok like that: not mixing matching and other `if`
                if let Some(manager_rx) = res.manager_receiver.as_mut() {
                    if !manager_rx.is_empty()
                        && let Some(message) = manager_rx.recv().await
                    {
                        let write_res =
                            socket_write.write_all(&DapParser::to_bytes(&message)).await;

                        match write_res {
                            Ok(()) => {}
                            Err(err) => {
                                error!(
                                    "Can't write manager message to frontend socket! Error: {err}"
                                );
                            }
                        }
                    }
                }
            }
        });

        tokio::spawn(async move {
            let mut parser = DapParser::new();

            let mut buff = vec![0; 8 * 1024];

            loop {
                match socket_read.read(&mut buff).await {
                    Ok(cnt) => {
                        parser.add_bytes(&buff[..cnt]);

                        loop {
                            let message = match parser.get_message() {
                                Some(Ok(message)) => Some(message),
                                Some(Err(err)) => {
                                    error!("Invalid DAP message received. Error: {err}");
                                    None
                                }
                                None => None,
                            };

                            let Some(message) = message else {
                                break;
                            };

                            let mut res = res1.lock().await;
                            if let Err(err) = res.dispatch_message(message).await {
                                error!("Can't handle DAP message. Error: {err}");
                            }
                        }
                    }
                    Err(err) => {
                        error!("Can't read from frontend socket! Error: {err}");
                    }
                }
            }
        });

        Ok(res)
    }

    /// Legacy single-client constructor for Windows — uses TCP on localhost.
    ///
    /// Binds a TCP listener on `127.0.0.1:0` (OS-assigned port), writes the
    /// port number to a file so the frontend can connect, then waits for a
    /// single connection.
    #[cfg(windows)]
    pub async fn new() -> Result<Arc<Mutex<Self>>, Box<dyn Error>> {
        let res = Arc::new(Mutex::new(Self {
            children: vec![],
            children_receivers: vec![],
            parent_senders: vec![],
            selected: 0,
            manager_receiver: None,
            manager_sender: None,
            daemon_state: None,
        }));

        let res1 = res.clone();
        let res2 = res.clone();

        let socket_dir: std::path::PathBuf;
        {
            let path = &CODETRACER_PATHS.lock()?;
            socket_dir = path.tmp_path.join("session-manager");
        }

        create_dir_all(&socket_dir).await?;

        // On Windows, write a port file instead of creating a Unix socket.
        let port_file = socket_dir.join(std::process::id().to_string() + ".port");

        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let local_addr = listener.local_addr()?;
        let port = local_addr.port();

        // Write the port number so the frontend can discover it.
        tokio::fs::write(&port_file, port.to_string()).await?;

        info!(
            "TCP listening on: 127.0.0.1:{} (port file: {})",
            port,
            port_file.display()
        );

        let mut socket_read;
        let mut socket_write;

        match listener.accept().await {
            Ok((socket, _addr)) => (socket_read, socket_write) = tokio::io::split(socket),
            Err(err) => return Err(Box::new(err)),
        }

        info!("Connected");

        let (manager_tx, manager_rx) = mpsc::unbounded_channel::<Value>();
        {
            let mut locked = res.lock().await;
            locked.manager_receiver = Some(manager_rx);
            locked.manager_sender = Some(manager_tx);
        }

        tokio::spawn(async move {
            loop {
                sleep(Duration::from_millis(10)).await;

                let mut res = res2.lock().await;
                for (replay_id, rx_opt) in res.children_receivers.iter_mut().enumerate() {
                    let Some(rx) = rx_opt else { continue };
                    if !rx.is_empty()
                        && let Some(message) = rx.recv().await
                    {
                        let message = tag_with_replay_id(message, replay_id);
                        let write_res =
                            socket_write.write_all(&DapParser::to_bytes(&message)).await;

                        match write_res {
                            Ok(()) => {}
                            Err(err) => {
                                error!("Can't write to frontend socket! Error: {err}");
                            }
                        }
                    }
                }

                #[allow(clippy::collapsible_if)]
                if let Some(manager_rx) = res.manager_receiver.as_mut() {
                    if !manager_rx.is_empty()
                        && let Some(message) = manager_rx.recv().await
                    {
                        let write_res =
                            socket_write.write_all(&DapParser::to_bytes(&message)).await;

                        match write_res {
                            Ok(()) => {}
                            Err(err) => {
                                error!(
                                    "Can't write manager message to frontend socket! Error: {err}"
                                );
                            }
                        }
                    }
                }
            }
        });

        tokio::spawn(async move {
            let mut parser = DapParser::new();

            let mut buff = vec![0; 8 * 1024];

            loop {
                match socket_read.read(&mut buff).await {
                    Ok(cnt) => {
                        parser.add_bytes(&buff[..cnt]);

                        loop {
                            let message = match parser.get_message() {
                                Some(Ok(message)) => Some(message),
                                Some(Err(err)) => {
                                    error!("Invalid DAP message received. Error: {err}");
                                    None
                                }
                                None => None,
                            };

                            let Some(message) = message else {
                                break;
                            };

                            let mut res = res1.lock().await;
                            if let Err(err) = res.dispatch_message(message).await {
                                error!("Can't handle DAP message. Error: {err}");
                            }
                        }
                    }
                    Err(err) => {
                        error!("Can't read from frontend socket! Error: {err}");
                    }
                }
            }
        });

        Ok(res)
    }

    // -----------------------------------------------------------------------
    // Daemon (multi-client) constructor
    // -----------------------------------------------------------------------

    /// Creates a `BackendManager` in **daemon mode** that accepts multiple
    /// concurrent client connections on the given `socket_path`.
    ///
    /// The daemon will:
    /// - Assign a unique numeric ID to each connecting client.
    /// - Route DAP responses back to the client that originated the request.
    /// - Broadcast DAP events to *all* connected clients.
    /// - Track per-trace sessions with TTL timers; expired sessions are
    ///   automatically stopped.
    /// - Auto-shutdown when no session has been loaded for the TTL, after
    ///   one was (the last session expired, or it was closed, stopped or
    ///   crashed and no other was opened since).
    /// - Shut down cleanly when `ct/daemon-shutdown` is received or a signal
    ///   is caught (see `shutdown_rx`).
    ///
    /// Returns `(Arc<Mutex<BackendManager>>, UnboundedReceiver<()>)`.
    /// The receiver fires when a `ct/daemon-shutdown` request is received
    /// (or auto-shutdown triggers), allowing the caller (main.rs) to tear
    /// down the process.
    #[cfg(unix)]
    pub async fn new_daemon(
        socket_path: PathBuf,
        config: DaemonConfig,
    ) -> Result<(Arc<Mutex<Self>>, UnboundedReceiver<()>), Box<dyn Error>> {
        let (shutdown_tx, shutdown_rx) = mpsc::unbounded_channel::<()>();

        let (session_manager, ttl_expiry_rx) =
            SessionManager::new(config.default_ttl, config.max_sessions);

        let mgr = Arc::new(Mutex::new(Self {
            children: vec![],
            children_receivers: vec![],
            parent_senders: vec![],
            selected: 0,
            manager_receiver: None,
            manager_sender: None,
            daemon_state: Some(DaemonState {
                clients: HashMap::new(),
                request_client_map: HashMap::new(),
                shutdown_tx: Some(shutdown_tx),
                session_manager,
                config,
                py_bridge: PyBridgeState::new(),
                inbound_tx: None,
                next_client_id: Arc::new(std::sync::atomic::AtomicU64::new(0)),
                next_daemon_seq: DAEMON_SEQ_BASE,
                self_ref: std::sync::Weak::new(),
            }),
        }));

        // Channel for the per-client read tasks to forward (client_id, message)
        // tuples into the central dispatch loop.
        let (inbound_tx, mut inbound_rx) = mpsc::unbounded_channel::<(u64, Value)>();
        let next_client_id = {
            let mut locked = mgr.lock().await;
            let ds = locked
                .daemon_state
                .as_mut()
                .expect("a daemon manager has daemon state");
            ds.inbound_tx = Some(inbound_tx.clone());
            ds.self_ref = Arc::downgrade(&mgr);
            ds.next_client_id.clone()
        };

        // Ensure socket directory exists and remove any stale socket file.
        if let Some(parent) = socket_path.parent() {
            create_dir_all(parent).await?;
        }
        _ = remove_file(&socket_path).await;

        let listener = bind_unix_listener(&socket_path)?;
        // Only this user may connect: the socket is the owner's alone, and
        // every connection is checked again by its peer's credentials below,
        // which holds whatever the directory's or the file's mode allows.
        restrict_socket_to_owner(&socket_path)?;
        info!("Daemon listening on: {}", socket_path.display());

        // --- Accept loop: spawns per-client read and write tasks. ---
        let mgr_accept = mgr.clone();
        tokio::spawn(async move {
            loop {
                match listener.accept().await {
                    Ok((socket, _addr)) => {
                        if let Err(refusal) = check_peer_is_this_user(&socket) {
                            warn!("Daemon: refused a connection: {refusal}");
                            continue;
                        }
                        let client_id =
                            next_client_id.fetch_add(1, std::sync::atomic::Ordering::Relaxed);

                        let (read_half, write_half) = tokio::io::split(socket);

                        // Each client gets a channel; the write task drains it.
                        let (client_tx, client_rx) = mpsc::unbounded_channel::<Value>();

                        // Register the client in daemon state.
                        {
                            let mut locked = mgr_accept.lock().await;
                            if let Some(ds) = locked.daemon_state.as_mut() {
                                ds.clients.insert(
                                    client_id,
                                    ClientHandle {
                                        sender: ClientSender::new(client_tx),
                                        script: None,
                                    },
                                );
                            }
                        }

                        info!("Daemon: client {client_id} connected");

                        // Spawn writer task for this client.
                        Self::spawn_client_writer(client_id, write_half, client_rx);

                        // Spawn reader task for this client.
                        Self::spawn_client_reader(
                            client_id,
                            read_half,
                            inbound_tx.clone(),
                            mgr_accept.clone(),
                        );
                    }
                    Err(e) => {
                        error!("Daemon accept error: {e}");
                    }
                }
            }
        });

        // --- Central dispatch loop: reads (client_id, message) from all
        //     client reader tasks and dispatches them through the manager. ---
        let mgr_dispatch = mgr.clone();
        tokio::spawn(async move {
            while let Some((client_id, message)) = inbound_rx.recv().await {
                let mut locked = mgr_dispatch.lock().await;

                locked.dispatch_client_message(client_id, message).await;
            }
        });

        // --- Response router: polls child receivers and manager_receiver,
        //     routes responses to the correct client and broadcasts events.
        //     Each message is tagged with the backend_id it came from so
        //     the Python bridge can correlate stopped events with backends. ---
        let mgr_router = mgr.clone();
        tokio::spawn(async move {
            loop {
                sleep(Duration::from_millis(10)).await;

                let mut locked = mgr_router.lock().await;

                // Collect messages from child receivers, tagged with backend index.
                let mut outbound: Vec<(Option<usize>, Value)> = Vec::new();
                for (idx, rx_opt) in locked.children_receivers.iter_mut().enumerate() {
                    if let Some(rx) = rx_opt {
                        while !rx.is_empty() {
                            if let Some(msg) = rx.recv().await {
                                outbound.push((Some(idx), msg));
                            }
                        }
                    }
                }

                // Collect messages from manager_receiver (no backend_id).
                if let Some(manager_rx) = locked.manager_receiver.as_mut() {
                    while !manager_rx.is_empty() {
                        if let Some(msg) = manager_rx.recv().await {
                            outbound.push((None, msg));
                        }
                    }
                }

                // Route each outbound message to the appropriate client(s).
                for (backend_id, msg) in outbound {
                    locked.route_daemon_message(backend_id, &msg);
                }
            }
        });

        // --- TTL expiry loop: receives trace paths whose idle timers
        //     have fired and stops the corresponding replays.  When
        //     the last session is removed, triggers auto-shutdown. ---
        let mgr_ttl = mgr.clone();
        tokio::spawn(Self::ttl_expiry_loop(mgr_ttl, ttl_expiry_rx));

        // --- Crash detection loop: periodically checks if child processes
        //     have died unexpectedly and cleans up their sessions. ---
        let mgr_crash = mgr.clone();
        tokio::spawn(Self::crash_detection_loop(mgr_crash));

        // --- Idle shutdown: no trace loaded for the TTL, after one was. ---
        tokio::spawn(Self::idle_shutdown_loop(mgr.clone()));

        Ok((mgr, shutdown_rx))
    }

    /// Daemon (multi-client) constructor for Windows — uses TCP on localhost.
    ///
    /// Binds a TCP listener on `127.0.0.1:0`, writes the port number to the
    /// `socket_path` file (which on Windows is actually a `.port` file), then
    /// accepts multiple concurrent client connections.
    #[cfg(windows)]
    pub async fn new_daemon(
        socket_path: PathBuf,
        config: DaemonConfig,
    ) -> Result<(Arc<Mutex<Self>>, UnboundedReceiver<()>), Box<dyn Error>> {
        let (shutdown_tx, shutdown_rx) = mpsc::unbounded_channel::<()>();

        let (session_manager, ttl_expiry_rx) =
            SessionManager::new(config.default_ttl, config.max_sessions);

        let mgr = Arc::new(Mutex::new(Self {
            children: vec![],
            children_receivers: vec![],
            parent_senders: vec![],
            selected: 0,
            manager_receiver: None,
            manager_sender: None,
            daemon_state: Some(DaemonState {
                clients: HashMap::new(),
                request_client_map: HashMap::new(),
                shutdown_tx: Some(shutdown_tx),
                session_manager,
                config,
                py_bridge: PyBridgeState::new(),
                inbound_tx: None,
                next_client_id: Arc::new(std::sync::atomic::AtomicU64::new(0)),
                next_daemon_seq: DAEMON_SEQ_BASE,
                self_ref: std::sync::Weak::new(),
            }),
        }));

        // Channel for the per-client read tasks to forward (client_id, message)
        // tuples into the central dispatch loop.
        let (inbound_tx, mut inbound_rx) = mpsc::unbounded_channel::<(u64, Value)>();

        // Ensure the port file directory exists.
        if let Some(parent) = socket_path.parent() {
            create_dir_all(parent).await?;
        }

        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let local_addr = listener.local_addr()?;
        let port = local_addr.port();

        // Write the port number to the port file so clients can discover it.
        tokio::fs::write(&socket_path, port.to_string()).await?;
        info!(
            "Daemon listening on: 127.0.0.1:{} (port file: {})",
            port,
            socket_path.display()
        );

        // --- Accept loop: spawns per-client read and write tasks. ---
        let mgr_accept = mgr.clone();
        tokio::spawn(async move {
            let mut next_client_id: u64 = 0;
            loop {
                match listener.accept().await {
                    Ok((socket, _addr)) => {
                        let client_id = next_client_id;
                        next_client_id += 1;

                        let (read_half, write_half) = tokio::io::split(socket);

                        // Each client gets a channel; the write task drains it.
                        let (client_tx, client_rx) = mpsc::unbounded_channel::<Value>();

                        // Register the client in daemon state.
                        {
                            let mut locked = mgr_accept.lock().await;
                            if let Some(ds) = locked.daemon_state.as_mut() {
                                ds.clients.insert(
                                    client_id,
                                    ClientHandle {
                                        sender: ClientSender::new(client_tx),
                                        script: None,
                                    },
                                );
                            }
                        }

                        info!("Daemon: client {client_id} connected");

                        // Spawn writer task for this client.
                        Self::spawn_client_writer(client_id, write_half, client_rx);

                        // Spawn reader task for this client.
                        Self::spawn_client_reader(
                            client_id,
                            read_half,
                            inbound_tx.clone(),
                            mgr_accept.clone(),
                        );
                    }
                    Err(e) => {
                        error!("Daemon accept error: {e}");
                    }
                }
            }
        });

        // --- Central dispatch loop ---
        let mgr_dispatch = mgr.clone();
        tokio::spawn(async move {
            while let Some((client_id, message)) = inbound_rx.recv().await {
                let mut locked = mgr_dispatch.lock().await;

                if let Some(seq) = message.get("seq").and_then(Value::as_i64)
                    && let Some(ds) = locked.daemon_state.as_mut()
                {
                    ds.request_client_map.insert(seq, client_id);
                }

                if let Err(err) = locked.dispatch_message(message).await {
                    error!("Daemon: dispatch error for client {client_id}: {err}");
                }
            }
        });

        // --- Response router ---
        let mgr_router = mgr.clone();
        tokio::spawn(async move {
            loop {
                sleep(Duration::from_millis(10)).await;

                let mut locked = mgr_router.lock().await;

                let mut outbound: Vec<(Option<usize>, Value)> = Vec::new();
                for (idx, rx_opt) in locked.children_receivers.iter_mut().enumerate() {
                    if let Some(rx) = rx_opt {
                        while !rx.is_empty() {
                            if let Some(msg) = rx.recv().await {
                                outbound.push((Some(idx), msg));
                            }
                        }
                    }
                }

                if let Some(manager_rx) = locked.manager_receiver.as_mut() {
                    while !manager_rx.is_empty() {
                        if let Some(msg) = manager_rx.recv().await {
                            outbound.push((None, msg));
                        }
                    }
                }

                for (backend_id, msg) in outbound {
                    locked.route_daemon_message(backend_id, &msg);
                }
            }
        });

        // --- TTL expiry loop ---
        let mgr_ttl = mgr.clone();
        tokio::spawn(Self::ttl_expiry_loop(mgr_ttl, ttl_expiry_rx));

        // --- Crash detection loop ---
        let mgr_crash = mgr.clone();
        tokio::spawn(Self::crash_detection_loop(mgr_crash));

        // --- Idle shutdown: no trace loaded for the TTL, after one was. ---
        tokio::spawn(Self::idle_shutdown_loop(mgr.clone()));

        Ok((mgr, shutdown_rx))
    }

    /// Spawns a task that reads DAP messages from a client's socket and forwards
    /// `(client_id, message)` tuples to the central dispatch channel.
    #[cfg(unix)]
    fn spawn_client_reader(
        client_id: u64,
        mut read_half: tokio::io::ReadHalf<UnixStream>,
        inbound_tx: UnboundedSender<(u64, Value)>,
        mgr: Arc<Mutex<Self>>,
    ) {
        tokio::spawn(async move {
            let mut parser = DapParser::new();
            let mut buf = vec![0u8; 8 * 1024];

            loop {
                match read_half.read(&mut buf).await {
                    Ok(0) => {
                        // EOF — client disconnected.
                        info!("Daemon: client {client_id} disconnected (EOF)");
                        Self::remove_client(&mgr, client_id).await;
                        break;
                    }
                    Ok(cnt) => {
                        parser.add_bytes(&buf[..cnt]);
                        loop {
                            match parser.get_message() {
                                Some(Ok(message)) => {
                                    if inbound_tx.send((client_id, message)).is_err() {
                                        // Dispatch channel closed — daemon is shutting down.
                                        return;
                                    }
                                }
                                Some(Err(err)) => {
                                    error!("Daemon: bad DAP from client {client_id}: {err}");
                                }
                                None => break,
                            }
                        }
                    }
                    Err(err) => {
                        error!("Daemon: read error for client {client_id}: {err}");
                        Self::remove_client(&mgr, client_id).await;
                        break;
                    }
                }
            }
        });
    }

    /// Spawns a task that drains a per-client channel and writes DAP-framed
    /// messages to the client's socket.
    #[cfg(unix)]
    fn spawn_client_writer(
        client_id: u64,
        mut write_half: WriteHalf<UnixStream>,
        mut rx: UnboundedReceiver<Value>,
    ) {
        tokio::spawn(async move {
            while let Some(message) = rx.recv().await {
                let bytes = DapParser::to_bytes(&message);
                if let Err(err) = write_half.write_all(&bytes).await {
                    error!("Daemon: write error for client {client_id}: {err}");
                    break;
                }
            }
        });
    }

    /// Spawns a task that reads DAP messages from a client's TCP socket and
    /// forwards `(client_id, message)` tuples to the central dispatch channel.
    #[cfg(windows)]
    fn spawn_client_reader(
        client_id: u64,
        mut read_half: tokio::io::ReadHalf<TcpStream>,
        inbound_tx: UnboundedSender<(u64, Value)>,
        mgr: Arc<Mutex<Self>>,
    ) {
        tokio::spawn(async move {
            let mut parser = DapParser::new();
            let mut buf = vec![0u8; 8 * 1024];

            loop {
                match read_half.read(&mut buf).await {
                    Ok(0) => {
                        info!("Daemon: client {client_id} disconnected (EOF)");
                        Self::remove_client(&mgr, client_id).await;
                        break;
                    }
                    Ok(cnt) => {
                        parser.add_bytes(&buf[..cnt]);
                        loop {
                            match parser.get_message() {
                                Some(Ok(message)) => {
                                    if inbound_tx.send((client_id, message)).is_err() {
                                        return;
                                    }
                                }
                                Some(Err(err)) => {
                                    error!("Daemon: bad DAP from client {client_id}: {err}");
                                }
                                None => break,
                            }
                        }
                    }
                    Err(err) => {
                        error!("Daemon: read error for client {client_id}: {err}");
                        Self::remove_client(&mgr, client_id).await;
                        break;
                    }
                }
            }
        });
    }

    /// Spawns a task that drains a per-client channel and writes DAP-framed
    /// messages to the client's TCP socket.
    #[cfg(windows)]
    fn spawn_client_writer(
        client_id: u64,
        mut write_half: WriteHalf<TcpStream>,
        mut rx: UnboundedReceiver<Value>,
    ) {
        tokio::spawn(async move {
            while let Some(message) = rx.recv().await {
                let bytes = DapParser::to_bytes(&message);
                if let Err(err) = write_half.write_all(&bytes).await {
                    error!("Daemon: write error for client {client_id}: {err}");
                    break;
                }
            }
        });
    }

    /// Removes a client from the daemon state when it disconnects.
    async fn remove_client(mgr: &Arc<Mutex<Self>>, client_id: u64) {
        let mut locked = mgr.lock().await;
        if let Some(ds) = locked.daemon_state.as_mut() {
            ds.clients.remove(&client_id);
            // Also clean up any pending request mappings for this client.
            ds.request_client_map.retain(|_seq, cid| *cid != client_id);
            info!(
                "Daemon: removed client {client_id}, {} remaining",
                ds.clients.len()
            );
        }
    }

    /// Routes a message from a child (or the manager itself) to the correct
    /// daemon client.
    ///
    /// - **Responses** (`type == "response"`): Routed to the client whose `seq`
    ///   is recorded in `request_client_map`.  The spec says the response
    ///   carries a `request_seq` field that matches the original request's `seq`.
    /// - **Events** (`type == "event"`): Broadcast to ALL connected clients.
    /// - **Other**: Broadcast to all clients as a fallback.
    ///
    /// The `backend_id` parameter identifies which child backend produced this
    /// message (`None` for manager-originated messages).  This is used by the
    /// Python bridge to correlate stopped events and stackTrace responses
    /// with the correct pending navigation operation.
    fn route_daemon_message(&mut self, backend_id: Option<usize>, msg: &Value) {
        let ds = match self.daemon_state.as_mut() {
            Some(ds) => ds,
            None => return, // not in daemon mode
        };

        let msg_type = msg.get("type").and_then(Value::as_str).unwrap_or("");

        // --- Python bridge: intercept stopped events for pending navigations ---
        //
        // When a navigation command (e.g., `next`) is sent on behalf of a
        // Python client, the backend responds with a `stopped` event.  We
        // intercept it here to advance the pending navigation to the
        // AwaitingStackTrace state and send a stackTrace request.
        if msg_type == "event" {
            let event_name = msg.get("event").and_then(Value::as_str).unwrap_or("");
            if (event_name == "stopped" || event_name == "terminated")
                && let Some(bid) = backend_id
            {
                // Check if any pending navigation is waiting for this stopped event.
                // We first allocate the seq number, then look for the pending entry,
                // to avoid borrowing pending_navigations and next_seq simultaneously.
                let st_seq = ds.py_bridge.next_seq();

                let should_send = if let Some(pending) =
                    ds.py_bridge.pending_navigations.iter_mut().find(|p| {
                        p.backend_id == bid && p.state == PendingPyNavState::AwaitingStopped
                    }) {
                    pending.state = PendingPyNavState::AwaitingStackTrace;
                    pending.stack_trace_seq = Some(st_seq);
                    true
                } else {
                    false
                };

                if should_send {
                    // Send a stackTrace request to the backend so we can
                    // extract the current location for the Python client.
                    let st_request = serde_json::json!({
                        "type": "request",
                        "command": "stackTrace",
                        "seq": st_seq,
                        "arguments": {"threadId": 1}
                    });
                    if let Some(sender) = self.parent_senders.get(bid).and_then(|s| s.as_ref()) {
                        let _ = sender.send(st_request);
                    }
                    // Don't return — still do normal routing for the stopped event
                    // so other clients can observe it.
                }
            }

            // Capture rrTicks from ct/complete-move events for pending navigations.
            //
            // The standard DAP stackTrace response does not include ticks
            // information, but the CodeTracer backend emits a ct/complete-move
            // event (between the stopped event and the stackTrace response)
            // that carries the rrTicks value in body.location.rrTicks.  We
            // capture it here so we can inject it into the final py-navigate
            // response.
            if event_name == "ct/complete-move"
                && let Some(bid) = backend_id
            {
                let rr_ticks = msg
                    .get("body")
                    .and_then(|b| b.get("location"))
                    .and_then(|loc| loc.get("rrTicks"))
                    .and_then(Value::as_i64);

                if let Some(ticks) = rr_ticks
                    && let Some(pending) = ds.py_bridge.pending_navigations.iter_mut().find(|p| {
                        p.backend_id == bid && p.state == PendingPyNavState::AwaitingStackTrace
                    })
                {
                    pending.rr_ticks = Some(ticks);
                }
                // Don't return — still route the event to clients normally.
            }

            // Detect end-of-trace from ct/notification events.
            //
            // The CodeTracer backend emits ct/notification events with text
            // like "End of record reached" or "Limit of record at the end
            // already reached!" when the trace replay cannot advance further.
            // We capture this as `end_of_trace` in the pending navigation so
            // it can be included in the final response as `endOfTrace: true`.
            if event_name == "ct/notification"
                && let Some(bid) = backend_id
            {
                let text = msg
                    .get("body")
                    .and_then(|b| b.get("text"))
                    .and_then(Value::as_str)
                    .unwrap_or("");

                if (text.contains("End of record") || text.contains("Limit of record"))
                    && let Some(pending) = ds.py_bridge.pending_navigations.iter_mut().find(|p| {
                        p.backend_id == bid
                            && (p.state == PendingPyNavState::AwaitingStopped
                                || p.state == PendingPyNavState::AwaitingStackTrace)
                    })
                {
                    pending.end_of_trace = true;
                }
                // Don't return — still route the event to clients normally.
            }

            // Intercept ct/updated-flow events from the backend.
            //
            // The backend's flow handler does NOT send a DAP response.
            // Instead, it emits a `ct/updated-flow` event containing the
            // flow data as a `FlowUpdate` object.  We intercept this event
            // here, find the pending Flow request, format the data, and
            // send it back to the Python client as a `ct/py-flow` response.
            //
            // The event body has the `FlowUpdate` schema:
            //   - `viewUpdates`: array of `FlowViewUpdate` objects, each
            //     containing `steps` and `loops`.
            //   - `error`: bool
            //   - `errorMessage`: string
            //   - `finished`: bool
            //
            // See: replay-server/src/task.rs — `FlowUpdate`, `FlowViewUpdate`
            if event_name == "ct/updated-flow" {
                // Find the pending Flow request for this backend.
                if let Some(idx) = ds
                    .py_bridge
                    .pending_requests
                    .iter()
                    .position(|p| p.kind == PendingPyRequestKind::Flow)
                {
                    let pending = ds.py_bridge.pending_requests.remove(idx);

                    let body = msg.get("body").unwrap_or(&Value::Null);
                    let is_error = body.get("error").and_then(Value::as_bool).unwrap_or(false);

                    if is_error {
                        let error_message = body
                            .get("errorMessage")
                            .and_then(Value::as_str)
                            .unwrap_or("flow error");
                        let py_response = serde_json::json!({
                            "type": "response",
                            "request_seq": pending.original_seq,
                            "success": false,
                            "command": "ct/py-flow",
                            "message": error_message,
                        });
                        self.send_to_client(pending.client_id, py_response);
                    } else {
                        // Extract steps and loops from viewUpdates.
                        let view_updates = body.get("viewUpdates").and_then(Value::as_array);

                        let mut all_steps = serde_json::json!([]);
                        let mut all_loops = serde_json::json!([]);

                        if let Some(updates) = view_updates {
                            let mut steps_vec: Vec<Value> = Vec::new();
                            let mut loops_vec: Vec<Value> = Vec::new();
                            for vu in updates {
                                if let Some(steps) = vu.get("steps").and_then(Value::as_array) {
                                    steps_vec.extend(steps.iter().cloned());
                                }
                                if let Some(loops) = vu.get("loops").and_then(Value::as_array) {
                                    loops_vec.extend(loops.iter().cloned());
                                }
                            }
                            all_steps = serde_json::json!(steps_vec);
                            all_loops = serde_json::json!(loops_vec);
                        }

                        let py_response = serde_json::json!({
                            "type": "response",
                            "request_seq": pending.original_seq,
                            "success": true,
                            "command": "ct/py-flow",
                            "body": {
                                "steps": all_steps,
                                "loops": all_loops,
                            },
                        });
                        self.send_to_client(pending.client_id, py_response);
                    }

                    // Don't broadcast — this is a bridge-internal event.
                    return;
                }
                // If there's no pending flow request, fall through to
                // normal event routing so other clients can see the event.
            }

            // Intercept ct/updated-calltrace events from the backend.
            //
            // The backend's calltrace handler sends a `ct/updated-calltrace`
            // event (not a DAP response) containing the calltrace data as a
            // `CallArgsUpdateResults` object.  We intercept this event here,
            // find the pending Calltrace request, format the data, and send
            // it back to the Python client as a `ct/py-calltrace` response.
            //
            // The event body has the `CallArgsUpdateResults` schema:
            //   - `callLines`: array of `CallLine` objects
            //   - `totalCallsCount`: usize
            //   - `scrollPosition`: usize
            //   - `startCallLineIndex`: usize
            //
            // See: replay-server/src/task.rs — `CallArgsUpdateResults`
            // See: replay-server/src/dap.rs — `updated_calltrace_event`
            if event_name == "ct/updated-calltrace"
                && let Some(idx) = ds
                    .py_bridge
                    .pending_requests
                    .iter()
                    .position(|p| p.kind == PendingPyRequestKind::Calltrace)
            {
                let pending = ds.py_bridge.pending_requests.remove(idx);
                let body = msg.get("body").unwrap_or(&Value::Null);

                // Extract the call lines from the body and transform them
                // into a simplified `calls` array for the Python client.
                // Each call line has `content.call.rawName` and
                // `content.call.location` which we expose as top-level
                // fields.
                let call_lines = body
                    .get("callLines")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default();

                let mut calls = Vec::new();
                for cl in &call_lines {
                    if let Some(content) = cl.get("content")
                        && let Some(call) = content.get("call")
                    {
                        // Bridge naming differences between the Rust
                        // `Call` struct and the Python API:
                        //   rawName -> name (function name)
                        //   content.count -> childrenCount
                        let mut enriched = call.clone();
                        if let Some(obj) = enriched.as_object_mut()
                            && let Some(raw_name) = call.get("rawName")
                        {
                            obj.insert("name".to_string(), raw_name.clone());
                        }
                        // Propagate children count from the enclosing
                        // CallLine content into the call object.
                        if let Some(count) = content.get("count") {
                            enriched
                                .as_object_mut()
                                .map(|obj| obj.insert("childrenCount".to_string(), count.clone()));
                        }
                        calls.push(enriched);
                    }
                }

                let py_response = serde_json::json!({
                    "type": "response",
                    "request_seq": pending.original_seq,
                    "success": true,
                    "command": "ct/py-calltrace",
                    "body": {
                        "calls": calls,
                        "callLines": call_lines,
                        "totalCallsCount": body.get("totalCallsCount").unwrap_or(&Value::Null),
                    },
                });
                self.send_to_client(pending.client_id, py_response);
                return;
            }

            // Intercept ct/calltrace-search-res events from the backend.
            //
            // The backend's calltrace search handler sends a
            // `ct/calltrace-search-res` event (not a DAP response) containing
            // an array of `Call` objects matching the search query.
            //
            // See: replay-server/src/dap.rs — `calltrace_search_event`
            if event_name == "ct/calltrace-search-res"
                && let Some(idx) = ds
                    .py_bridge
                    .pending_requests
                    .iter()
                    .position(|p| p.kind == PendingPyRequestKind::SearchCalltrace)
            {
                let pending = ds.py_bridge.pending_requests.remove(idx);
                let body = msg.get("body").unwrap_or(&Value::Null);

                // The body is directly an array of Call objects.
                let calls = if body.is_array() {
                    body.clone()
                } else {
                    serde_json::json!([])
                };

                let py_response = serde_json::json!({
                    "type": "response",
                    "request_seq": pending.original_seq,
                    "success": true,
                    "command": "ct/py-search-calltrace",
                    "body": {
                        "calls": calls,
                    },
                });
                self.send_to_client(pending.client_id, py_response);
                return;
            }

            // Intercept ct/updated-events from the backend.
            //
            // The backend's event_load handler sends a `ct/updated-events`
            // event containing an array of `ProgramEvent` objects, followed
            // by a `ct/updated-events-content` event with the raw content.
            // We intercept the first event here to build the response.
            //
            // See: replay-server/src/dap.rs — `updated_events`
            if event_name == "ct/updated-events"
                && let Some(idx) = ds
                    .py_bridge
                    .pending_requests
                    .iter()
                    .position(|p| p.kind == PendingPyRequestKind::Events)
            {
                let pending = ds.py_bridge.pending_requests.remove(idx);
                let body = msg.get("body").unwrap_or(&Value::Null);

                // The body is directly an array of ProgramEvent objects.
                let events = if body.is_array() {
                    body.clone()
                } else {
                    serde_json::json!([])
                };

                let py_response = serde_json::json!({
                    "type": "response",
                    "request_seq": pending.original_seq,
                    "success": true,
                    "command": "ct/py-events",
                    "body": {
                        "events": events,
                    },
                });
                self.send_to_client(pending.client_id, py_response);
                return;
            }

            // Silently consume ct/updated-events-content events — the content
            // is supplementary and the main events response has already been
            // sent above when we processed ct/updated-events.
            if event_name == "ct/updated-events-content" {
                // Nothing to do — just prevent broadcasting.
                return;
            }

            // Intercept ct/loaded-terminal events from the backend.
            //
            // The backend's load_terminal handler sends a `ct/loaded-terminal`
            // event containing an array of `ProgramEvent` objects representing
            // terminal output (Write events).
            //
            // See: replay-server/src/dap.rs — `loaded_terminal_event`
            if event_name == "ct/loaded-terminal"
                && let Some(idx) = ds
                    .py_bridge
                    .pending_requests
                    .iter()
                    .position(|p| p.kind == PendingPyRequestKind::Terminal)
            {
                let pending = ds.py_bridge.pending_requests.remove(idx);
                let body = msg.get("body").unwrap_or(&Value::Null);

                // The body is an array of ProgramEvent objects.
                // Extract the content from each event and concatenate
                // into a single output string.
                let mut output = String::new();
                if let Some(events) = body.as_array() {
                    for event in events {
                        if let Some(content) = event.get("content").and_then(Value::as_str) {
                            output.push_str(content);
                        }
                    }
                }

                let py_response = serde_json::json!({
                    "type": "response",
                    "request_seq": pending.original_seq,
                    "success": true,
                    "command": "ct/py-terminal",
                    "body": {
                        "output": output,
                        "events": body,
                    },
                });
                self.send_to_client(pending.client_id, py_response);
                return;
            }

            // Intercept ct/tracepoint-results events from the backend.
            //
            // After `ct/run-tracepoints` finishes, the backend emits a
            // `ct/tracepoint-results` event carrying all tracepoint hits
            // as `TracepointResultsAggregate`.  We intercept it here to
            // build the `ct/py-run-tracepoints` response for the Python
            // client.
            //
            // See: replay-server/src/handler.rs — `run_tracepoints()`
            // See: replay-server/src/dap.rs — `tracepoint_results_event()`
            if event_name == "ct/tracepoint-results"
                && let Some(idx) = ds
                    .py_bridge
                    .pending_requests
                    .iter()
                    .position(|p| p.kind == PendingPyRequestKind::RunTracepoints)
            {
                let pending = ds.py_bridge.pending_requests.remove(idx);
                // The backend answers the request right after this event;
                // consume that answer here rather than broadcast it.
                ds.py_bridge.pending_requests.push(PendingPyRequest {
                    kind: PendingPyRequestKind::Unobserved(
                        python_bridge::UnobservedReason::RunTracepointsAnswer,
                    ),
                    client_id: 0,
                    original_seq: 0,
                    backend_seq: pending.backend_seq,
                    response_command: String::new(),
                    expression: String::new(),
                });
                let body = msg.get("body").unwrap_or(&Value::Null);

                // Extract Stop objects from the results array and convert
                // each into the simplified Python-facing schema.
                let results_raw = body
                    .get("results")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default();

                let results: Vec<Value> = results_raw
                    .iter()
                    .map(|stop| {
                        // Extract values from the Stop's `locals` array.
                        // Each local is a StringAndValueTuple with fields
                        // `first` (name) and `second` (Value object).
                        let values: Vec<Value> = stop
                            .get("locals")
                            .and_then(Value::as_array)
                            .map(|locals| {
                                locals
                                    .iter()
                                    .map(|local| {
                                        let name = local
                                            .get("first")
                                            .and_then(Value::as_str)
                                            .unwrap_or("");
                                        let value =
                                            python_bridge::extract_value_str(local.get("second"));
                                        json!({"name": name, "value": value})
                                    })
                                    .collect()
                            })
                            .unwrap_or_default();

                        json!({
                            "tracepointId": stop.get("tracepointId")
                                .and_then(Value::as_i64).unwrap_or(0),
                            "path": stop.get("path")
                                .and_then(Value::as_str).unwrap_or(""),
                            "line": stop.get("line")
                                .and_then(Value::as_i64).unwrap_or(0),
                            "ticks": stop.get("rrTicks")
                                .and_then(Value::as_i64).unwrap_or(0),
                            "iteration": stop.get("resultIndex")
                                .and_then(Value::as_i64).unwrap_or(0),
                            "values": values,
                        })
                    })
                    .collect();

                let errors = body.get("errors").cloned().unwrap_or_else(|| json!({}));

                let py_response = serde_json::json!({
                    "type": "response",
                    "request_seq": pending.original_seq,
                    "success": true,
                    "command": "ct/py-run-tracepoints",
                    "body": {
                        "results": results,
                        "errors": errors,
                    },
                });
                self.send_to_client(pending.client_id, py_response);
                return;
            }

            // Silently consume ct/updated-trace events when a
            // RunTracepoints request is pending — these per-tracepoint
            // updates are internal to the tracepoint run and should not
            // be broadcast while a Python client is waiting for the
            // aggregate ct/tracepoint-results event.
            if event_name == "ct/updated-trace"
                && ds
                    .py_bridge
                    .pending_requests
                    .iter()
                    .any(|p| p.kind == PendingPyRequestKind::RunTracepoints)
            {
                return;
            }
        }

        // --- Python bridge: intercept responses for pending navigations ---
        //
        // Two kinds of bridge-internal responses must be intercepted:
        //
        // 1. **Navigation command responses** (e.g., response to `next` with
        //    seq 1000000): these are the DAP acknowledgement of the navigation
        //    command.  The bridge does not need them — only the subsequent
        //    `stopped` event matters.  We silently consume these so they are
        //    not broadcast to clients.
        //
        // 2. **stackTrace responses**: after we send a `stackTrace` request
        //    in response to a `stopped` event, the backend returns the current
        //    location.  We extract it, build a simplified response, and send
        //    it to the Python client.
        if msg_type == "response"
            && let Some(req_seq) = msg.get("request_seq").and_then(Value::as_i64)
        {
            // Re-borrow daemon_state to check pending navigations.
            let ds = match self.daemon_state.as_mut() {
                Some(ds) => ds,
                None => return,
            };

            // Check if this response is for a bridge-initiated navigation command
            // (e.g., the response to our `next`/`stepIn` DAP request).
            //
            // On success: consume it silently — we only care about the
            // subsequent `stopped` event.
            //
            // On failure: the backend could not process the navigation
            // command (e.g., `ct/goto-ticks` is not supported).  In this
            // case, no `stopped` event will ever arrive, so we must
            // complete the pending navigation immediately with an error
            // to avoid the client hanging indefinitely.
            if let Some(idx) = ds
                .py_bridge
                .pending_navigations
                .iter()
                .position(|p| p.nav_command_seq == Some(req_seq))
            {
                let nav_success = msg.get("success").and_then(Value::as_bool).unwrap_or(true);

                if nav_success {
                    // Silently consume — don't forward to any client.
                    // The subsequent `stopped` event will advance the
                    // state machine.  A command that answered success
                    // without reaching its target (a seek answered
                    // `false`) is remembered and answered as an error once
                    // the location arrives.
                    let command_name = msg.get("command").and_then(Value::as_str).unwrap_or("");
                    if let Some(reason) =
                        python_bridge::navigation_not_reached_reason(command_name, msg)
                    {
                        ds.py_bridge.pending_navigations[idx].not_reached = Some(reason);
                    }
                    return;
                }

                // The backend returned an error for the navigation command.
                // Remove the pending navigation and send an error response
                // back to the originating client.
                let pending = ds.py_bridge.pending_navigations.remove(idx);
                let error_message = msg
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("navigation command failed");
                let command_name = msg
                    .get("command")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown");
                let py_error = serde_json::json!({
                    "type": "response",
                    "request_seq": pending.original_seq,
                    "success": false,
                    "command": "ct/py-navigate",
                    "message": format!("backend error for {command_name}: {error_message}"),
                });
                self.send_to_client(pending.client_id, py_error);
                return;
            }

            // Check if this is a stackTrace response for a pending navigation.
            if let Some(idx) = ds.py_bridge.pending_navigations.iter().position(|p| {
                p.stack_trace_seq == Some(req_seq)
                    && p.state == PendingPyNavState::AwaitingStackTrace
            }) {
                let pending = ds.py_bridge.pending_navigations.remove(idx);
                if let Some(reason) = pending.not_reached {
                    let py_error = serde_json::json!({
                        "type": "response",
                        "request_seq": pending.original_seq,
                        "success": false,
                        "command": "ct/py-navigate",
                        "message": reason,
                    });
                    self.send_to_client(pending.client_id, py_error);
                    return;
                }
                let mut location = python_bridge::extract_location_from_stack_trace(msg);

                // Inject rrTicks captured from the ct/complete-move event if
                // the stackTrace response did not already include ticks.
                // The standard DAP stackTrace response does not carry ticks,
                // but the ct/complete-move event emitted by the CodeTracer
                // backend does, and we captured it earlier.
                if let Some(rr_ticks) = pending.rr_ticks {
                    let current_ticks = location.get("ticks").and_then(Value::as_i64).unwrap_or(0);
                    if current_ticks == 0 {
                        location["ticks"] = serde_json::json!(rr_ticks);
                    }
                }

                // Inject endOfTrace if detected from ct/notification events.
                if pending.end_of_trace {
                    location["endOfTrace"] = serde_json::json!(true);
                }

                let py_response = serde_json::json!({
                    "type": "response",
                    "request_seq": pending.original_seq,
                    "success": true,
                    "command": "ct/py-navigate",
                    "body": location,
                });
                self.send_to_client(pending.client_id, py_response);
                // Don't do normal routing for this bridge-internal response.
                return;
            }

            // --- Python bridge: intercept responses for pending py-requests ---
            //
            // Simple request-response operations (locals, evaluate, stack trace)
            // are tracked by `PendingPyRequest`.  When the backend responds with
            // a matching `request_seq`, we format the response and send it to
            // the Python client.
            if let Some(idx) = ds
                .py_bridge
                .pending_requests
                .iter()
                .position(|p| p.backend_seq == req_seq)
            {
                let pending = ds.py_bridge.pending_requests.remove(idx);

                // Responses this daemon deliberately does not inspect,
                // each carrying the reason that made not inspecting it
                // safe (see `UnobservedReason`).  Silently consume.
                if matches!(pending.kind, PendingPyRequestKind::Unobserved(_)) {
                    return;
                }

                // `ct/py-remove-watchpoint`: the re-sent
                // `setDataBreakpoints` states the set MINUS the removed
                // entry, so the removal succeeded iff the backend
                // accepted the re-send.  A refusal means the engine is
                // still watching, so the watchpoint goes back into the
                // daemon's table and the client is told the truth --
                // NOT `removed: true`, which is what this path used to
                // answer before the backend saw anything.
                if let PendingPyRequestKind::RemoveWatchpoint {
                    session: trace_path,
                    wp_id,
                    expression,
                } = &pending.kind
                {
                    let accepted = msg.get("success").and_then(Value::as_bool).unwrap_or(false);
                    let py_response = if accepted {
                        json!({
                            "type": "response",
                            "request_seq": pending.original_seq,
                            "success": true,
                            "command": "ct/py-remove-watchpoint",
                            "body": {"removed": true},
                        })
                    } else {
                        let message = msg
                            .get("message")
                            .and_then(Value::as_str)
                            .unwrap_or("backend refused the watchpoint removal");
                        let message = format!(
                            "the watchpoint is still live: the backend refused the                              setDataBreakpoints that would have removed it ({message})"
                        );
                        if let Some(ds) = self.daemon_state.as_mut() {
                            ds.py_bridge
                                .breakpoint_state_mut(trace_path)
                                .restore_watchpoint(*wp_id, expression);
                        }
                        json!({
                            "type": "response",
                            "request_seq": pending.original_seq,
                            "success": false,
                            "command": "ct/py-remove-watchpoint",
                            "message": message,
                        })
                    };
                    self.send_to_client(pending.client_id, py_response);
                    return;
                }

                // `ct/py-add-breakpoint` and `ct/py-add-watchpoint`: the
                // backend's per-entry `verified` flag decides whether
                // these succeeded, and they are handled here rather than
                // in the formatter table below because a refusal also
                // has to be rolled back out of the daemon's own table.
                let point_verdict = match &pending.kind {
                    PendingPyRequestKind::AddBreakpoint {
                        session: trace_path,
                        bp_id,
                        index,
                    } => Some((
                        python_bridge::format_add_breakpoint_response(msg, *index, *bp_id),
                        trace_path.clone(),
                        *bp_id,
                        false,
                    )),
                    PendingPyRequestKind::AddWatchpoint {
                        session: trace_path,
                        wp_id,
                        index,
                    } => Some((
                        python_bridge::format_add_watchpoint_response(msg, *index, *wp_id),
                        trace_path.clone(),
                        *wp_id,
                        true,
                    )),
                    _ => None,
                };

                if let Some(((success, body_or_error), trace_path, point_id, is_watchpoint)) =
                    point_verdict
                {
                    if !success {
                        // Drop the point the backend refused, so it is
                        // not re-sent with every subsequent add for this
                        // file — and so a later `remove_*` cannot be
                        // answered for an id that never bound.
                        if let Some(ds) = self.daemon_state.as_mut() {
                            let state = ds.py_bridge.breakpoint_state_mut(&trace_path);
                            if is_watchpoint {
                                state.forget_watchpoint(point_id);
                            } else {
                                state.forget_breakpoint(point_id);
                            }
                        }
                    }

                    let py_response = if success {
                        serde_json::json!({
                            "type": "response",
                            "request_seq": pending.original_seq,
                            "success": true,
                            "command": pending.response_command,
                            "body": body_or_error,
                        })
                    } else {
                        let mut refusal = serde_json::json!({
                            "type": "response",
                            "request_seq": pending.original_seq,
                            "success": false,
                            "command": pending.response_command,
                            "message": body_or_error.get("message")
                                .and_then(Value::as_str)
                                .unwrap_or("unknown error"),
                        });
                        // Carry the backend's CLOSED-SET refusal code
                        // through to the client when there is one (see
                        // `ct_data_breakpoints::DataBreakpointRefusal`).
                        // Without it the caller has to parse English to
                        // tell "you named something this recording never
                        // captured" from "this kind of watchpoint is not
                        // possible over a recording at all" — two
                        // refusals with entirely different fixes.
                        let structured: serde_json::Map<String, Value> = ["refusalCode", "refusal"]
                            .iter()
                            .filter_map(|k| {
                                body_or_error.get(*k).map(|v| ((*k).to_string(), v.clone()))
                            })
                            .collect();
                        if !structured.is_empty() {
                            refusal["body"] = Value::Object(structured);
                        }
                        refusal
                    };
                    self.send_to_client(pending.client_id, py_response);
                    return;
                }

                let (success, body_or_error) = match pending.kind {
                    PendingPyRequestKind::Locals => python_bridge::format_locals_response(msg),
                    PendingPyRequestKind::Evaluate => {
                        python_bridge::format_evaluate_response(msg, &pending.expression)
                    }
                    PendingPyRequestKind::StackTrace => {
                        python_bridge::format_stack_trace_response(msg)
                    }
                    PendingPyRequestKind::Flow => python_bridge::format_flow_response(msg),
                    PendingPyRequestKind::Calltrace => {
                        python_bridge::format_calltrace_response(msg)
                    }
                    PendingPyRequestKind::SearchCalltrace => {
                        python_bridge::format_search_calltrace_response(msg)
                    }
                    PendingPyRequestKind::Events => python_bridge::format_events_response(msg),
                    PendingPyRequestKind::Terminal => python_bridge::format_terminal_response(msg),
                    PendingPyRequestKind::ReadSource => {
                        python_bridge::format_read_source_response(msg)
                    }
                    PendingPyRequestKind::Processes => {
                        python_bridge::format_processes_response(msg)
                    }
                    PendingPyRequestKind::SelectProcess => {
                        python_bridge::format_select_process_response(msg)
                    }
                    PendingPyRequestKind::RunTracepoints => {
                        // A sweep that succeeds is answered from its
                        // ct/tracepoint-results event, which comes before
                        // this answer and retires this entry. Reaching it
                        // here means there was no event: a refusal (or a
                        // success without results), which the Python client
                        // must still be answered with, or it waits for ever.
                        python_bridge::format_run_tracepoints_answer(msg)
                    }
                    PendingPyRequestKind::OriginChain => {
                        // Forward the OriginChain wire shape verbatim (spec §4.1).
                        python_bridge::format_origin_chain_response(msg)
                    }
                    PendingPyRequestKind::ResolveVariableStep => {
                        // The variable name was stashed in ``pending.expression``
                        // at request-dispatch time (same convention as Evaluate),
                        // so the formatter can pick the matching local from
                        // the backend's history update.
                        python_bridge::format_resolve_variable_step_response(
                            msg,
                            &pending.expression,
                        )
                    }
                    PendingPyRequestKind::AddBreakpoint { .. }
                    | PendingPyRequestKind::AddWatchpoint { .. }
                    | PendingPyRequestKind::RemoveWatchpoint { .. }
                    | PendingPyRequestKind::Unobserved(_) => {
                        // All are answered above; unreachable.
                        return;
                    }
                };

                let py_response = if success {
                    serde_json::json!({
                        "type": "response",
                        "request_seq": pending.original_seq,
                        "success": true,
                        "command": pending.response_command,
                        "body": body_or_error,
                    })
                } else {
                    serde_json::json!({
                        "type": "response",
                        "request_seq": pending.original_seq,
                        "success": false,
                        "command": pending.response_command,
                        "message": body_or_error.get("message")
                            .and_then(Value::as_str)
                            .unwrap_or("unknown error"),
                    })
                };

                self.send_to_client(pending.client_id, py_response);
                // Consume this backend response — don't forward to clients.
                return;
            }
        }

        // --- Normal routing (existing logic) ---
        // Re-acquire ds since we may have dropped the previous borrow.
        let ds = match self.daemon_state.as_mut() {
            Some(ds) => ds,
            None => return,
        };

        match msg_type {
            "response" => {
                // Try to find the originating client via request_seq.
                if let Some(request_seq) = msg.get("request_seq").and_then(Value::as_i64)
                    && let Some(client_id) = ds.request_client_map.remove(&request_seq)
                    && let Some(handle) = ds.clients.get(&client_id)
                {
                    if let Err(err) = handle.sender.send(msg.clone()) {
                        error!("Daemon: can't send response to client {client_id}: {err}");
                    }
                    return;
                }
                // Fallback: broadcast if we can't map the response.
                Self::broadcast_to_clients(ds, msg);
            }
            "event" => {
                Self::broadcast_to_clients(ds, msg);
            }
            _ => {
                // Unknown type — broadcast as a best-effort fallback.
                Self::broadcast_to_clients(ds, msg);
            }
        }
    }

    /// Sends `msg` to every connected daemon client.
    ///
    /// A confined script's connection is left out: it is answered its own
    /// requests only, and never sees another session's events or answers.
    fn broadcast_to_clients(ds: &DaemonState, msg: &Value) {
        for (cid, handle) in ds.clients.iter().filter(|(_, h)| h.script.is_none()) {
            if let Err(err) = handle.sender.send(msg.clone()) {
                error!("Daemon: can't broadcast to client {cid}: {err}");
            }
        }
    }

    // -----------------------------------------------------------------------
    // TTL expiry and session lifecycle
    // -----------------------------------------------------------------------

    /// Background loop that receives TTL-expired trace paths and cleans up
    /// the corresponding replay sessions.
    ///
    /// When the last session is removed (and at least one session existed),
    /// triggers automatic daemon shutdown.
    async fn ttl_expiry_loop(
        mgr: Arc<Mutex<Self>>,
        mut ttl_expiry_rx: UnboundedReceiver<SessionKey>,
    ) {
        while let Some(trace_path) = ttl_expiry_rx.recv().await {
            let mut locked = mgr.lock().await;

            let ds = match locked.daemon_state.as_mut() {
                Some(ds) => ds,
                None => continue,
            };

            // Remove the session (this also aborts its timer, though the
            // timer already fired in this case).
            if let Some(backend_id) = ds.session_manager.remove_session(&trace_path) {
                info!("TTL expired for session {trace_path} (backend_id={backend_id})");

                // Stop the child replay process.
                if let Err(e) = locked.stop_replay(backend_id).await {
                    warn!(
                        "Failed to stop replay {backend_id} for expired session {trace_path}: {e}"
                    );
                }

                // Re-borrow daemon_state after the mutable borrow from stop_replay.
                let ds = match locked.daemon_state.as_mut() {
                    Some(ds) => ds,
                    None => continue,
                };

                // Auto-shutdown when the last session expires.
                // We know at least one session existed (we just removed it),
                // so if the count is now 0, all sessions are gone.
                if ds.session_manager.session_count() == 0 {
                    info!("All sessions expired — initiating auto-shutdown");
                    if let Some(tx) = ds.shutdown_tx.take() {
                        let _ = tx.send(());
                    }
                }
            }
        }
    }

    /// Background loop that shuts the daemon down once it has had no trace
    /// loaded for its TTL, after it had one.
    ///
    /// codetracer-pm `spec/Planned-Features/CodeTracer-MCP-Server.md`, "Daemon
    /// Lifecycle": the daemon "auto-starts on first CLI/MCP use and
    /// self-terminates on idle". [`Self::ttl_expiry_loop`] covers the trace
    /// whose own TTL ran out. A trace that ends any other way (its client
    /// closes it, `ct/close-trace`, as `trace query` does when its script is
    /// done; `ct/stop-replay`; a crashed backend) used to leave the daemon with
    /// nothing loaded and nothing to end it, so a daemon `trace query` had
    /// auto-started ran until it was killed. The TTL counts from the moment
    /// the last trace went away ([`SessionManager::emptied_at`]); opening a
    /// trace in the meantime starts the count again. A daemon that never had
    /// a trace is left running, as before.
    async fn idle_shutdown_loop(mgr: Arc<Mutex<Self>>) {
        // Fine enough against a TTL of seconds (tests) or minutes (default).
        let interval = Duration::from_secs(1);
        loop {
            sleep(interval).await;
            let mut locked = mgr.lock().await;
            let Some(ds) = locked.daemon_state.as_mut() else {
                continue;
            };
            let ttl = ds.session_manager.default_ttl();
            let idle_for_the_ttl = ds.session_manager.session_count() == 0
                && ds
                    .session_manager
                    .emptied_at()
                    .is_some_and(|emptied| emptied.elapsed() >= ttl);
            if idle_for_the_ttl {
                info!("No trace has been loaded for {ttl:?} — initiating auto-shutdown");
                if let Some(tx) = ds.shutdown_tx.take() {
                    let _ = tx.send(());
                }
                return;
            }
        }
    }

    /// Background loop that periodically checks if any child backend
    /// processes have died unexpectedly (e.g. crashed or were killed).
    ///
    /// When a dead child is detected, the corresponding session is removed
    /// from the session manager and the backend slot is cleaned up.  An
    /// error event is broadcast to all connected clients so they know the
    /// session is no longer available.
    async fn crash_detection_loop(mgr: Arc<Mutex<Self>>) {
        // Check every 2 seconds.  This is a balance between responsiveness
        // and lock contention.
        let interval = Duration::from_secs(2);

        loop {
            sleep(interval).await;

            let mut locked = mgr.lock().await;

            // First pass: collect (path, backend_id) pairs for all sessions.
            let sessions: Vec<(SessionKey, usize)> = {
                let ds = match locked.daemon_state.as_ref() {
                    Some(ds) => ds,
                    None => continue,
                };
                ds.session_manager
                    .list_sessions()
                    .iter()
                    .map(|s| (s.key.clone(), s.backend_id))
                    .collect()
            };

            // Second pass: check which backends are dead (only borrows
            // locked.children, not daemon_state).
            let mut dead_sessions: Vec<(SessionKey, usize)> = Vec::new();
            for (path, backend_id) in &sessions {
                if let Some(true) = locked.is_child_dead(*backend_id) {
                    dead_sessions.push((path.clone(), *backend_id));
                }
            }

            // Third pass: clean up dead sessions.
            for (path, backend_id) in dead_sessions {
                warn!("Crash detected for backend {backend_id} (session: {path})");

                if let Some(ds) = locked.daemon_state.as_mut() {
                    ds.session_manager.remove_session(&path);

                    // Broadcast an error event to all clients.
                    let event = json!({
                        "type": "event",
                        "event": "ct/session-crashed",
                        "body": {
                            "tracePath": path.trace_path.to_string_lossy(),
                            "hostSourceReads": path.host_source_reads.is_allowed(),
                            "backendId": backend_id,
                            "message": "backend process exited unexpectedly",
                        }
                    });
                    Self::broadcast_to_clients(ds, &event);
                }

                // Clean up the child slot (don't call stop_replay, it's
                // already dead).
                if let Some(child_opt) = locked.children.get_mut(backend_id) {
                    *child_opt = None;
                }
                if let Some(rx_opt) = locked.children_receivers.get_mut(backend_id) {
                    if let Some(rx) = rx_opt {
                        rx.close();
                    }
                    *rx_opt = None;
                }
                if let Some(tx_opt) = locked.parent_senders.get_mut(backend_id) {
                    *tx_opt = None;
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Shared helpers
    // -----------------------------------------------------------------------

    fn send_manager_message(&self, message: Value) {
        if let Some(sender) = &self.manager_sender
            && let Err(err) = sender.send(message)
        {
            error!("Can't enqueue manager message. Error: {err}");
        }
    }

    /// Dispatch one message from daemon client `client_id`: admitted
    /// ([`Self::admit_client_message`]), recorded for routing its answer,
    /// and handled with a panic contained to it.  A handler that panics
    /// fails its own request (the client is told) and nothing else: without
    /// the containment the panic ended the dispatch loop, and with it the
    /// daemon's answers to every client and every trace.
    async fn dispatch_client_message(&mut self, client_id: u64, message: Value) {
        // A confined script's connection is admitted only its own
        // trace's queries; a client no longer registered (a script
        // run that ended) is not answered at all.
        let message = match self.admit_client_message(client_id, message) {
            Ok(message) => message,
            Err(None) => return,
            Err(Some(refusal)) => {
                self.send_to_client(client_id, refusal);
                return;
            }
        };
        let mut message = message;
        let command = message
            .get("command")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();

        // A request is dispatched under a `seq` of the daemon's, unique
        // across clients, and its answer routed by it ([`ClientSender`]).
        let mut seq = message.get("seq").and_then(Value::as_i64);
        if message.get("type").and_then(Value::as_str) == Some("request")
            && let Some(own_seq) = seq
            && let Some(ds) = self.daemon_state.as_mut()
        {
            let daemon_seq = ds.next_daemon_seq;
            ds.next_daemon_seq += 1;
            if let Some(handle) = ds.clients.get(&client_id) {
                handle.sender.number(daemon_seq, own_seq);
            }
            message["seq"] = json!(daemon_seq);
            seq = Some(daemon_seq);
        }

        // Track which client sent this request (if it has a seq number).
        if let Some(seq) = seq
            && let Some(ds) = self.daemon_state.as_mut()
        {
            ds.request_client_map.insert(seq, client_id);
        }

        // The dispatch loop holds the manager lock, so these are precisely
        // the resources this request can create. Keep existing sessions and
        // bridge state when a cached session's request fails.
        let first_backend = self.children.len();
        let previous_selection = self.selected;
        let (sessions, bridge_keys, bridge_seq) = self
            .daemon_state
            .as_ref()
            .map(|ds| {
                (
                    ds.session_manager.session_keys(),
                    ds.py_bridge
                        .breakpoint_states
                        .keys()
                        .cloned()
                        .collect::<Vec<_>>(),
                    ds.py_bridge.next_seq,
                )
            })
            .unwrap_or_default();
        let mut failure = {
            let outcome = std::panic::AssertUnwindSafe(self.dispatch_message(message))
                .catch_unwind()
                .await;
            match outcome {
                Ok(Ok(())) => return,
                Ok(Err(err)) => err.to_string(),
                Err(payload) => panic_text(payload.as_ref()),
            }
        };
        // Reap before answering: a failed request must never publish a
        // failure while a backend it started still runs without an owner.
        for id in first_backend..self.children.len() {
            if let Err(err) = self.cleanup_replay_slot(id).await {
                failure.push_str(&format!("; cleanup of backend {id} failed: {err}"));
            }
        }
        self.selected = previous_selection;
        if let Some(ds) = self.daemon_state.as_mut() {
            for session in ds.session_manager.list_sessions() {
                if !sessions.contains(&session.key)
                    && self
                        .children
                        .get(session.backend_id)
                        .is_none_or(|child| child.is_none())
                {
                    ds.session_manager.remove_session(&session.key);
                }
            }
            let retained_sessions = ds.session_manager.session_keys();
            ds.py_bridge.breakpoint_states.retain(|key, _| {
                bridge_keys.contains(key)
                    || (!sessions.contains(key) && retained_sessions.contains(key))
            });
            ds.py_bridge
                .pending_requests
                .retain(|request| request.backend_seq < bridge_seq);
            ds.py_bridge
                .pending_navigations
                .retain(|request| Some(request.original_seq) != seq);
            if let Some(seq) = seq {
                ds.request_client_map.remove(&seq);
            }
        }
        error!("Daemon: handling `{command}` for client {client_id} failed: {failure}");
        if let Some(seq) = seq {
            self.send_to_client(client_id, json!({
                "type": "response",
                "request_seq": seq,
                "success": false,
                "command": command,
                "message": format!("the session manager failed handling `{command}`: {failure}"),
            }));
        }
    }

    /// What the dispatch loop does with `message` from `client_id`:
    /// `Ok` to dispatch it (as [`ScriptGrant::admit`] rewrote it, for a
    /// confined script's connection), `Err(Some(answer))` to answer it with
    /// a refusal, `Err(None)` to drop it (its client is no longer registered:
    /// a script whose run ended, or a client that disconnected).
    fn admit_client_message(&self, client_id: u64, message: Value) -> Result<Value, Option<Value>> {
        let Some(ds) = self.daemon_state.as_ref() else {
            return Ok(message);
        };
        let Some(handle) = ds.clients.get(&client_id) else {
            return Err(None);
        };
        let Some(grant) = &handle.script else {
            return Ok(message);
        };
        let seq = message.get("seq").cloned().unwrap_or(Value::Null);
        let command = message.get("command").cloned().unwrap_or(Value::Null);
        grant.admit(message).map_err(|refusal| {
            warn!("Daemon: refused a script's request: {refusal}");
            Some(json!({
                "type": "response",
                "request_seq": seq,
                "success": false,
                "command": command,
                "message": refusal,
            }))
        })
    }

    /// Register the connection a confined script inherits: a socket pair
    /// whose daemon end is read and answered like an accepted client, under
    /// `grant`.  Returns the client id (to revoke it when the run ends) and
    /// the script's end.
    #[cfg(unix)]
    fn register_script_client(
        &mut self,
        grant: ScriptGrant,
    ) -> Result<(u64, std::os::fd::OwnedFd), String> {
        let ds = self
            .daemon_state
            .as_mut()
            .ok_or("a confined script needs the session manager's daemon mode")?;
        let mgr = ds
            .self_ref
            .upgrade()
            .ok_or("the session manager is shutting down")?;
        let inbound_tx = ds
            .inbound_tx
            .clone()
            .ok_or("the session manager is shutting down")?;
        let (daemon_end, script_end) = std::os::unix::net::UnixStream::pair()
            .map_err(|e| format!("cannot create the script's connection: {e}"))?;
        daemon_end
            .set_nonblocking(true)
            .map_err(|e| format!("cannot set up the script's connection: {e}"))?;
        let daemon_end = UnixStream::from_std(daemon_end)
            .map_err(|e| format!("cannot set up the script's connection: {e}"))?;
        let client_id = ds
            .next_client_id
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let (client_tx, client_rx) = mpsc::unbounded_channel::<Value>();
        ds.clients.insert(
            client_id,
            ClientHandle {
                sender: ClientSender::new(client_tx),
                script: Some(grant),
            },
        );
        let (read_half, write_half) = tokio::io::split(daemon_end);
        Self::spawn_client_writer(client_id, write_half, client_rx);
        Self::spawn_client_reader(client_id, read_half, inbound_tx, mgr);
        info!("Daemon: client {client_id} is a confined script's connection");
        Ok((client_id, std::os::fd::OwnedFd::from(script_end)))
    }

    /// In daemon mode, sends a message directly to a specific client
    /// (bypassing the manager_sender channel).
    fn send_to_client(&self, client_id: u64, message: Value) {
        if let Some(ds) = &self.daemon_state {
            if let Some(handle) = ds.clients.get(&client_id) {
                if let Err(err) = handle.sender.send(message) {
                    error!("Daemon: can't send to client {client_id}: {err}");
                }
            } else {
                warn!("Daemon: client {client_id} not found for direct send");
            }
        }
    }

    fn check_id(&self, id: usize) -> Result<(), Box<dyn Error>> {
        match self.children.get(id).and_then(|c| c.as_ref()) {
            Some(_) => Ok(()),
            None => Err(Box::new(InvalidID(id))),
        }
    }

    /// Spawns a child process and sets up DAP channels, but does NOT install
    /// the channels into the `children_receivers` / `parent_senders` vectors.
    ///
    /// The caller is responsible for running DAP initialization (or any other
    /// pre-routing handshake) and then calling [`install_replay_channels`] to
    /// make the channels available for the daemon's response router.
    ///
    /// Returns `(backend_id, sender_to_child, receiver_from_child)`.
    pub async fn start_replay_raw(
        &mut self,
        cmd: &str,
        args: &[&str],
    ) -> Result<(usize, UnboundedSender<Value>, UnboundedReceiver<Value>), Box<dyn Error>> {
        let first_backend = self.children.len();
        let result = self
            .start_replay_raw_inner(cmd, args)
            .await
            .map_err(|err| err.to_string());
        if result.is_err() {
            for id in first_backend..self.children.len() {
                self.cleanup_replay_slot(id).await?;
            }
        }
        result.map_err(Into::into)
    }

    #[cfg(unix)]
    async fn start_replay_raw_inner(
        &mut self,
        cmd: &str,
        args: &[&str],
    ) -> Result<(usize, UnboundedSender<Value>, UnboundedReceiver<Value>), Box<dyn Error>> {
        let socket_dir: std::path::PathBuf;
        {
            let path = &CODETRACER_PATHS.lock()?.tmp_path;
            socket_dir = path
                .join("session-manager")
                .join(std::process::id().to_string());
        }

        create_dir_all(&socket_dir).await?;

        // Reserve a slot for the child process.
        self.children.push(None);
        let id = self.children.len() - 1;

        // Also reserve placeholder slots in the channel vectors so that
        // `install_replay_channels` can use indexed assignment later.
        self.children_receivers.push(None);
        self.parent_senders.push(None);

        let socket_path = socket_dir.join(id.to_string() + ".sock");
        _ = remove_file(&socket_path).await;

        let cmd_text = cmd;
        // make it easier for dogfooding
        let mut cmd = if let Ok(_record_backend) = std::env::var("CODETRACER_RECORD_BACKEND") {
            let mut ct_cmd = Command::new("ct");
            ct_cmd.arg("record");
            ct_cmd.arg(cmd_text);
            ct_cmd
        } else {
            Command::new(cmd_text)
        };
        cmd.args(args);

        match socket_path.to_str() {
            Some(p) => {
                cmd.arg(p);
            }
            None => return Err(Box::new(SocketPathError)),
        }

        let listener = bind_unix_listener(&socket_path)?;

        #[cfg(windows)]
        cmd.creation_flags(CREATE_NO_WINDOW);

        cmd.kill_on_drop(true);
        let child = cmd.spawn();
        let child = match child {
            Ok(c) => c,
            Err(err) => {
                error!("Can't start replay: {err}");
                return Err(Box::new(err));
            }
        };

        self.children[id] = Some(child);
        info!("Starting replay with id {id}. Command: {cmd:?}",);

        let socket_read;
        let mut socket_write;

        info!("Awaiting connection!");

        let accepted = accept_unless_exited(
            self.children[id].as_mut().expect("just registered child"),
            listener.accept(),
            cmd_text,
            &socket_path.display(),
        )
        .await?;
        match accepted {
            Ok((socket, _addr)) => (socket_read, socket_write) = tokio::io::split(socket),
            Err(err) => return Err(Box::new(err)),
        }

        info!("Accepted connection!");

        // Create the channel pair for communication with the child process.
        // `child_tx` feeds into `child_rx` (messages FROM child TO the daemon).
        // `parent_tx` feeds into `parent_rx` (messages FROM the daemon TO the child).
        let (child_tx, child_rx) = mpsc::unbounded_channel();
        let (parent_tx, mut parent_rx) = mpsc::unbounded_channel::<Value>();

        // Spawn the writer task: drains parent_rx and writes to the child socket.
        tokio::spawn(async move {
            while let Some(message) = parent_rx.recv().await {
                let write_res = socket_write.write_all(&DapParser::to_bytes(&message)).await;
                match write_res {
                    Ok(()) => {
                        debug!("Sent message {message:?} to replay socket with id {id}");
                    }
                    Err(err) => {
                        error!("Can't send message to replay socket! Error: {err}");
                    }
                }
            }
        });

        // Spawn the reader task: reads from the child socket and sends to child_tx.
        tokio::spawn(async move {
            let mut parser = DapParser::new();
            let mut read_half = socket_read;
            let mut buff = vec![0; 8 * 1024];

            loop {
                match read_half.read(&mut buff).await {
                    Ok(0) => {
                        // EOF — child closed the connection.
                        info!("Replay {id}: child connection closed (EOF)");
                        break;
                    }
                    Ok(cnt) => {
                        parser.add_bytes(&buff[..cnt]);

                        loop {
                            let message = match parser.get_message() {
                                Some(Ok(message)) => Some(message),
                                Some(Err(err)) => {
                                    warn!("Recieved malformed DAP message! Error: {err}");
                                    None
                                }
                                None => None,
                            };

                            let Some(message) = message else {
                                break;
                            };

                            if let Err(err) = child_tx.send(message) {
                                error!("Can't send to child channel! Error: {err}");
                            }
                        }
                    }
                    Err(err) => {
                        error!("Can't read from replay socket! Error: {err}");
                    }
                }
            }
        });

        Ok((id, parent_tx, child_rx))
    }

    /// Windows implementation of `start_replay_raw` using TCP on localhost.
    ///
    /// Creates a TCP listener on `127.0.0.1:0`, passes the `host:port`
    /// address as the last argument to the child process (same convention as
    /// Unix where the socket path is the last argument), then waits for the
    /// child to connect back.
    #[cfg(windows)]
    async fn start_replay_raw_inner(
        &mut self,
        cmd: &str,
        args: &[&str],
    ) -> Result<(usize, UnboundedSender<Value>, UnboundedReceiver<Value>), Box<dyn Error>> {
        // Reserve a slot for the child process.
        self.children.push(None);
        let id = self.children.len() - 1;

        // Also reserve placeholder slots in the channel vectors.
        self.children_receivers.push(None);
        self.parent_senders.push(None);

        // Bind a TCP listener on a random port.
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let local_addr = listener.local_addr()?;
        let addr_str = local_addr.to_string();

        let cmd_text = cmd;
        let mut cmd = if let Ok(_record_backend) = std::env::var("CODETRACER_RECORD_BACKEND") {
            let mut ct_cmd = Command::new("ct");
            ct_cmd.arg("record");
            ct_cmd.arg(cmd_text);
            ct_cmd
        } else {
            Command::new(cmd_text)
        };
        cmd.args(args);

        // Pass the TCP address as the last argument (same convention as Unix
        // socket path).
        cmd.arg(&addr_str);

        #[cfg(windows)]
        cmd.creation_flags(CREATE_NO_WINDOW);

        cmd.kill_on_drop(true);
        let child = cmd.spawn();
        let child = match child {
            Ok(c) => c,
            Err(err) => {
                error!("Can't start replay: {err}");
                return Err(Box::new(err));
            }
        };

        self.children[id] = Some(child);
        info!("Starting replay with id {id}. Listening on {addr_str}");

        let socket_read;
        let mut socket_write;

        info!("Awaiting connection!");

        let accepted = accept_unless_exited(
            self.children[id].as_mut().expect("just registered child"),
            listener.accept(),
            cmd_text,
            &addr_str,
        )
        .await?;
        match accepted {
            Ok((socket, _addr)) => (socket_read, socket_write) = tokio::io::split(socket),
            Err(err) => return Err(Box::new(err)),
        }

        info!("Accepted connection!");

        let (child_tx, child_rx) = mpsc::unbounded_channel();
        let (parent_tx, mut parent_rx) = mpsc::unbounded_channel::<Value>();

        // Spawn the writer task.
        tokio::spawn(async move {
            while let Some(message) = parent_rx.recv().await {
                let write_res = socket_write.write_all(&DapParser::to_bytes(&message)).await;
                match write_res {
                    Ok(()) => {
                        debug!("Sent message {message:?} to replay socket with id {id}");
                    }
                    Err(err) => {
                        error!("Can't send message to replay socket! Error: {err}");
                    }
                }
            }
        });

        // Spawn the reader task.
        tokio::spawn(async move {
            let mut parser = DapParser::new();
            let mut read_half = socket_read;
            let mut buff = vec![0; 8 * 1024];

            loop {
                match read_half.read(&mut buff).await {
                    Ok(0) => {
                        info!("Replay {id}: child connection closed (EOF)");
                        break;
                    }
                    Ok(cnt) => {
                        parser.add_bytes(&buff[..cnt]);

                        loop {
                            let message = match parser.get_message() {
                                Some(Ok(message)) => Some(message),
                                Some(Err(err)) => {
                                    warn!("Recieved malformed DAP message! Error: {err}");
                                    None
                                }
                                None => None,
                            };

                            let Some(message) = message else {
                                break;
                            };

                            if let Err(err) = child_tx.send(message) {
                                error!("Can't send to child channel! Error: {err}");
                            }
                        }
                    }
                    Err(err) => {
                        error!("Can't read from replay socket! Error: {err}");
                    }
                }
            }
        });

        Ok((id, parent_tx, child_rx))
    }

    /// Installs the DAP channels for a previously-started replay, making it
    /// available for normal message routing by the daemon's response router.
    ///
    /// This is the second half of the split `start_replay` flow.  The
    /// `backend_id` must have been obtained from a prior [`start_replay_raw`]
    /// call.
    pub fn install_replay_channels(
        &mut self,
        backend_id: usize,
        parent_tx: UnboundedSender<Value>,
        child_rx: UnboundedReceiver<Value>,
    ) {
        // The slots were pre-allocated by start_replay_raw.
        if let Some(slot) = self.children_receivers.get_mut(backend_id) {
            *slot = Some(child_rx);
        }
        if let Some(slot) = self.parent_senders.get_mut(backend_id) {
            *slot = Some(parent_tx);
        }
    }

    /// Spawns a child process, sets up DAP channels, and immediately installs
    /// them for the daemon's response router.
    ///
    /// This is the original `start_replay` behavior, preserved for backward
    /// compatibility.  It delegates to [`start_replay_raw`] +
    /// [`install_replay_channels`].
    pub async fn start_replay(
        &mut self,
        cmd: &str,
        args: &[&str],
    ) -> Result<usize, Box<dyn Error>> {
        let (id, parent_tx, child_rx) = self.start_replay_raw(cmd, args).await?;
        self.install_replay_channels(id, parent_tx, child_rx);
        Ok(id)
    }

    pub async fn stop_replay(&mut self, id: usize) -> Result<(), Box<dyn Error>> {
        info!("Stopping replay with id {id}");

        self.check_id(id)?;
        self.cleanup_replay_slot(id).await
    }

    /// Teardown also accepts a reserved slot whose spawn failed: its bound
    /// socket and channels still belong to the failed request.
    async fn cleanup_replay_slot(&mut self, id: usize) -> Result<(), Box<dyn Error>> {
        let mut failures = Vec::new();
        if let Some(child_opt) = self.children.get_mut(id) {
            if let Some(subprocess) = child_opt.as_mut()
                && let Err(err) = subprocess.kill().await
            {
                failures.push(format!("cannot reap replay {id}: {err}"));
            }
            // Keep the owner handle when the OS refuses termination. The
            // session stays registered, and the failure names cleanup too.
            if failures.is_empty() {
                *child_opt = None;
            }
        }

        if let Some(rx_opt) = self.children_receivers.get_mut(id) {
            if let Some(rx) = rx_opt {
                rx.close();
            }
            *rx_opt = None;
        }

        if let Some(tx_opt) = self.parent_senders.get_mut(id) {
            *tx_opt = None;
        }
        #[cfg(unix)]
        {
            let socket = CODETRACER_PATHS
                .lock()?
                .tmp_path
                .join("session-manager")
                .join(std::process::id().to_string())
                .join(format!("{id}.sock"));
            match remove_file(socket).await {
                Ok(()) => {}
                Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
                Err(err) => failures.push(format!("cannot remove replay {id} socket: {err}")),
            }
        }
        if self.selected == id && failures.is_empty() {
            self.selected = usize::MAX;
        }

        if failures.is_empty() {
            info!("Stopped replay {id}");
            Ok(())
        } else {
            Err(failures.join("; ").into())
        }
    }

    pub fn select_replay(&mut self, id: usize) -> Result<(), Box<dyn Error>> {
        self.check_id(id)?;

        info!("Selecting replay {id}");
        self.selected = id;

        Ok(())
    }

    /// Central message dispatcher.
    ///
    /// In daemon mode, the optional `client_id` parameter (set by the
    /// dispatch loop in `new_daemon`) is available via `request_client_map`
    /// so that `ct/ping` and `ct/daemon-shutdown` can respond to the right
    /// client.
    async fn dispatch_message(&mut self, message: Value) -> Result<(), Box<dyn Error>> {
        let msg = match message.as_object() {
            Some(obj) => obj,
            None => return self.message_selected(message).await,
        };

        let msg_type = match msg.get("type").and_then(Value::as_str) {
            Some(t) => t,
            None => return self.message_selected(message).await,
        };

        match msg_type {
            "request" => {
                let req_type = match msg.get("command").and_then(Value::as_str) {
                    Some(c) => c,
                    None => return self.message_selected(message).await,
                };

                let args = msg.get("arguments");
                let seq = msg.get("seq").and_then(Value::as_i64).unwrap_or(0);

                match req_type {
                    // A handler that panics, for the test of the dispatch
                    // loop's containment (`a_panicking_handler_fails_its_own_request_only`);
                    // compiled into test builds only.
                    #[cfg(test)]
                    "ct/test-panic" => panic!("a test handler panicked"),
                    // Routing tests need a genuinely deferred answer. Sending
                    // to a missing backend is an error and must be answered.
                    #[cfg(test)]
                    "ct/test-deferred-answer" => Ok(()),
                    "ct/start-replay" => {
                        if let Some(Value::Array(arr)) = args
                            && let Some(Value::String(command)) = arr.first()
                        {
                            let mut cmd_args: Vec<&str> = Vec::new();
                            for arg in arr.iter().skip(1) {
                                if let Some(s) = arg.as_str() {
                                    cmd_args.push(s);
                                } else {
                                    // TODO: return error
                                    return Ok(());
                                }
                            }

                            // Derive a canonical trace path from the full argument list.
                            // In the real MCP scenario the first argument is the
                            // replay tool and subsequent arguments identify the trace.
                            // We join all arguments into a single key so that
                            // different sessions are distinguished.
                            //
                            // The replay this starts is launched by its
                            // client, with whatever launch arguments that
                            // client sends, so the daemon does not restrict
                            // its source reads: it is a host-reads session,
                            // and a client asking for recording sources only
                            // (`ct/open-trace` without `hostSourceReads`) is
                            // never routed to it.
                            let trace_path = SessionKey::new(
                                Self::trace_path_from_args(command, &cmd_args),
                                HostSourceReads::Allowed,
                            );

                            // In daemon mode, check session limits before starting.
                            if let Some(ds) = self.daemon_state.as_mut() {
                                if ds.session_manager.has_session(&trace_path) {
                                    // Session already loaded — return existing ID.
                                    if let Some(existing_id) =
                                        ds.session_manager.get_session_backend_id(&trace_path)
                                    {
                                        ds.session_manager.reset_ttl(&trace_path);
                                        let response = json!({
                                            "type": "response",
                                            "request_seq": seq,
                                            "success": true,
                                            "command": "ct/start-replay",
                                            "body": {
                                                "replayId": existing_id
                                            }
                                        });
                                        self.answer_request(seq, response);
                                        return Ok(());
                                    }
                                }

                                // Check max sessions limit.
                                if ds.session_manager.session_count() >= ds.config.max_sessions {
                                    let response = json!({
                                        "type": "response",
                                        "request_seq": seq,
                                        "success": false,
                                        "command": "ct/start-replay",
                                        "message": format!(
                                            "maximum number of sessions ({}) reached",
                                            ds.config.max_sessions
                                        )
                                    });
                                    self.answer_request(seq, response);
                                    return Ok(());
                                }
                            }

                            // A start that fails is ANSWERED, like the refusal
                            // above: the client waits for this response and
                            // the request has no deadline, so an error only
                            // logged here left it waiting for ever, and the
                            // GUI drew its panes over a session with no
                            // backend.  The message names the cause: a socket
                            // path too long to bind (`SocketPathTooLong`
                            // names the path and the limit), a command that
                            // could not be started.
                            let replay_id = match self.start_replay(command, &cmd_args).await {
                                Ok(replay_id) => replay_id,
                                Err(err) => {
                                    let message =
                                        format!("could not start the replay `{command}`: {err}");
                                    error!("ct/start-replay: {message}");
                                    let response = json!({
                                        "type": "response",
                                        "request_seq": seq,
                                        "success": false,
                                        "command": "ct/start-replay",
                                        "message": message
                                    });
                                    self.answer_request(seq, response);
                                    return Ok(());
                                }
                            };

                            // Register the session in the session manager.
                            if let Some(ds) = self.daemon_state.as_mut()
                                && let Err(e) = ds
                                    .session_manager
                                    .add_session(trace_path.clone(), replay_id)
                            {
                                warn!("Failed to register session for {trace_path}: {e}");
                            }

                            let response = json!({
                                "type": "response",
                                "request_seq": seq,
                                "success": true,
                                "command": "ct/start-replay",
                                "body": {
                                    "replayId": replay_id
                                }
                            });
                            self.answer_request(seq, response);
                            return Ok(());
                        } else {
                            error!("problem with start-replay: can't process {args:?}");
                        }
                        // TODO: return error
                        Ok(())
                    }
                    "ct/stop-replay" => {
                        if let Some(Value::Number(num)) = args
                            && let Some(id) = num.as_u64()
                        {
                            let backend_id = id as usize;

                            // Remove the session from the session manager (if tracked).
                            if let Some(ds) = self.daemon_state.as_mut()
                                && let Some(path) =
                                    ds.session_manager.path_for_backend_id(backend_id)
                            {
                                ds.session_manager.remove_session(&path);
                            }

                            self.stop_replay(backend_id).await?;
                            return Ok(());
                        } else {
                            error!("problem with stop-replay: can't process {args:?}");
                        }
                        // TODO: return error
                        Ok(())
                    }
                    "ct/select-replay" => {
                        if let Some(Value::Number(num)) = args
                            && let Some(id) = num.as_u64()
                        {
                            self.select_replay(id as usize)?;
                            return Ok(());
                        } else {
                            error!("problem with select-replay: can't process {args:?}");
                        }
                        // TODO: return error
                        Ok(())
                    }
                    "ct/ping" => {
                        // Respond with a pong and, in daemon mode, the client ID.
                        let client_id = self.lookup_client_for_seq(seq);
                        let response = json!({
                            "type": "response",
                            "request_seq": seq,
                            "success": true,
                            "command": "ct/ping",
                            "body": {
                                "pong": true,
                                "clientId": client_id,
                            }
                        });
                        if self.daemon_state.is_some() {
                            if let Some(cid) = client_id {
                                self.send_to_client(cid, response);
                            }
                        } else {
                            self.send_manager_message(response);
                        }
                        Ok(())
                    }
                    "ct/daemon-shutdown" => {
                        info!("Received ct/daemon-shutdown request");
                        // Send acknowledgement first.
                        let response = json!({
                            "type": "response",
                            "request_seq": seq,
                            "success": true,
                            "command": "ct/daemon-shutdown",
                            "body": {
                                "message": "shutting down"
                            }
                        });
                        let client_id = self.lookup_client_for_seq(seq);
                        if self.daemon_state.is_some() {
                            if let Some(cid) = client_id {
                                self.send_to_client(cid, response);
                            }
                        } else {
                            self.send_manager_message(response);
                        }

                        // Trigger the shutdown channel.
                        if let Some(ds) = self.daemon_state.as_mut()
                            && let Some(tx) = ds.shutdown_tx.take()
                        {
                            let _ = tx.send(());
                        }
                        Ok(())
                    }
                    "ct/daemon-status" => {
                        info!("Received ct/daemon-status request");
                        let (sessions_count, traces) = if let Some(ds) = &self.daemon_state {
                            let infos = ds.session_manager.list_sessions();
                            let count = infos.len();
                            let paths: Vec<Value> = infos
                                .iter()
                                .map(|s| {
                                    Value::String(s.key.trace_path.to_string_lossy().to_string())
                                })
                                .collect();
                            (count, paths)
                        } else {
                            (0, Vec::new())
                        };

                        let response = json!({
                            "type": "response",
                            "request_seq": seq,
                            "success": true,
                            "command": "ct/daemon-status",
                            "body": {
                                "running": true,
                                "pid": std::process::id(),
                                "sessions": sessions_count,
                                "traces": traces,
                            }
                        });

                        let client_id = self.lookup_client_for_seq(seq);
                        if self.daemon_state.is_some() {
                            if let Some(cid) = client_id {
                                self.send_to_client(cid, response);
                            }
                        } else {
                            self.send_manager_message(response);
                        }
                        Ok(())
                    }
                    "ct/py-navigate" => self.handle_py_navigate(seq, args).await,
                    "ct/py-locals" => self.handle_py_locals(seq, args).await,
                    "ct/py-evaluate" => self.handle_py_evaluate(seq, args).await,
                    "ct/py-stack-trace" => self.handle_py_stack_trace(seq, args).await,
                    "ct/py-flow" => self.handle_py_flow(seq, args).await,
                    "ct/py-add-breakpoint" => self.handle_py_add_breakpoint(seq, args).await,
                    "ct/py-remove-breakpoint" => self.handle_py_remove_breakpoint(seq, args).await,
                    "ct/py-add-watchpoint" => self.handle_py_add_watchpoint(seq, args).await,
                    "ct/py-remove-watchpoint" => self.handle_py_remove_watchpoint(seq, args).await,
                    "ct/py-add-tracepoint" => self.handle_py_add_tracepoint(seq, args).await,
                    "ct/py-remove-tracepoint" => self.handle_py_remove_tracepoint(seq, args).await,
                    "ct/py-run-tracepoints" => self.handle_py_run_tracepoints(seq, args).await,
                    "ct/py-calltrace" => self.handle_py_calltrace(seq, args).await,
                    "ct/py-search-calltrace" => self.handle_py_search_calltrace(seq, args).await,
                    "ct/py-events" => self.handle_py_events(seq, args).await,
                    "ct/py-terminal" => self.handle_py_terminal(seq, args).await,
                    "ct/py-read-source" => self.handle_py_read_source(seq, args).await,
                    "ct/py-processes" => self.handle_py_processes(seq, args).await,
                    "ct/py-select-process" => self.handle_py_select_process(seq, args).await,
                    "ct/py-origin-chain" => self.handle_py_origin_chain(seq, args).await,
                    "ct/py-memory-diff" => self.handle_py_memory_diff(seq, args).await,
                    "ct/mcrMemoryDiff" => self.handle_py_memory_diff(seq, args).await,
                    "ct/py-memory-diff-record-vs-replay" => {
                        self.handle_py_memory_diff_record_vs_replay(seq, args).await
                    }
                    "ct/mcrMemoryDiffRecordVsReplay" => {
                        self.handle_py_memory_diff_record_vs_replay(seq, args).await
                    }
                    "ct/open-trace" => self.handle_open_trace(seq, args).await,
                    "ct/trace-info" => self.handle_trace_info(seq, args),
                    "ct/exec-script" => self.handle_exec_script(seq, args),
                    "ct/close-trace" => self.handle_close_trace(seq, args).await,
                    _ => {
                        if let Some(Value::Object(obj_args)) = args
                            && let Some(Value::Number(id)) = obj_args.get("replay-id")
                            && let Some(id) = id.as_u64()
                        {
                            let backend_id = id as usize;
                            // `replay-id` is a *routing* directive for this
                            // daemon, not part of any backend command's
                            // argument schema — note the kebab-case, unlike
                            // every camelCase DAP field.  Strip it before
                            // forwarding: several backend argument structs
                            // (e.g. `CtOriginChainArguments`) are
                            // `#[serde(deny_unknown_fields)]` and reject the
                            // whole request when it survives the hop.
                            let mut forwarded = message.clone();
                            if let Some(args) = forwarded
                                .get_mut("arguments")
                                .and_then(Value::as_object_mut)
                            {
                                args.remove("replay-id");
                            }
                            // Reset TTL for the session that owns this replay.
                            self.reset_ttl_for_backend_id(backend_id);
                            return self.message(backend_id, forwarded).await;
                        }
                        // Reset TTL for the currently selected replay.
                        self.reset_ttl_for_backend_id(self.selected);
                        self.message_selected(message).await
                    }
                }
            }
            "event" | "response" => self.message_selected(message).await,
            _ => self.message_selected(message).await,
        }
    }

    /// Sends `response`, the answer to request `seq`, to whoever asked: in
    /// daemon mode the client that sent it, otherwise (and for a request no
    /// client is recorded for) the manager channel, which the single-client
    /// session manager writes to its one connection.
    fn answer_request(&self, seq: i64, response: Value) {
        match self.lookup_client_for_seq(seq) {
            Some(client_id) => self.send_to_client(client_id, response),
            None => self.send_manager_message(response),
        }
    }

    /// Looks up which client sent the request with the given `seq` number.
    /// Returns `None` when not in daemon mode or when the seq is unknown.
    fn lookup_client_for_seq(&self, seq: i64) -> Option<u64> {
        self.daemon_state
            .as_ref()
            .and_then(|ds| ds.request_client_map.get(&seq).copied())
    }

    /// Derives a canonical trace path from the `ct/start-replay` arguments.
    ///
    /// The first argument is the command (replay tool binary), and subsequent
    /// arguments identify the trace / flags.  We join them all with spaces
    /// to form a canonical session key.
    fn trace_path_from_args(command: &str, args: &[&str]) -> PathBuf {
        let mut key = command.to_string();
        for arg in args {
            key.push(' ');
            key.push_str(arg);
        }
        PathBuf::from(key)
    }

    /// Resets the TTL timer for the session associated with the given
    /// backend replay ID.  No-op if not in daemon mode or if no session
    /// maps to `backend_id`.
    fn reset_ttl_for_backend_id(&mut self, backend_id: usize) {
        if let Some(ds) = self.daemon_state.as_mut()
            && let Some(path) = ds.session_manager.path_for_backend_id(backend_id)
        {
            ds.session_manager.reset_ttl(&path);
        }
    }

    // -----------------------------------------------------------------------
    // ct/py-navigate handler (Python bridge)
    // -----------------------------------------------------------------------

    /// Handles `ct/py-navigate` requests from Python clients.
    ///
    /// Translates the Python navigation method into a DAP command, sends it
    /// to the appropriate backend, and registers a pending navigation that
    /// will be completed asynchronously when the backend responds with a
    /// stopped event followed by a stackTrace response.
    ///
    /// # Wire protocol
    ///
    /// **Request:**
    /// ```json
    /// {
    ///   "type": "request",
    ///   "command": "ct/py-navigate",
    ///   "seq": 1,
    ///   "arguments": {
    ///     "tracePath": "/path/to/trace",
    ///     "method": "step_over"
    ///   }
    /// }
    /// ```
    ///
    /// **Response** (sent asynchronously after backend completes):
    /// ```json
    /// {
    ///   "type": "response",
    ///   "request_seq": 1,
    ///   "success": true,
    ///   "command": "ct/py-navigate",
    ///   "body": {
    ///     "path": "main.nim",
    ///     "line": 43,
    ///     "column": 1,
    ///     "ticks": 12345,
    ///     "endOfTrace": false
    ///   }
    /// }
    /// ```
    async fn handle_py_navigate(
        &mut self,
        seq: i64,
        args: Option<&Value>,
    ) -> Result<(), Box<dyn Error>> {
        let trace_path_str = match args
            .and_then(|a| a.get("tracePath"))
            .and_then(Value::as_str)
        {
            Some(p) => p.to_string(),
            None => {
                self.send_py_error(seq, "missing 'tracePath' in arguments");
                return Ok(());
            }
        };

        let method = match args.and_then(|a| a.get("method")).and_then(Value::as_str) {
            Some(m) => m.to_string(),
            None => {
                self.send_py_error(seq, "missing 'method' in arguments");
                return Ok(());
            }
        };

        let session = SessionKey::for_request(&trace_path_str, args);

        // Look up the backend for this trace.
        let backend_id = match self
            .daemon_state
            .as_ref()
            .and_then(|ds| ds.session_manager.get_session_backend_id(&session))
        {
            Some(id) => id,
            None => {
                self.send_py_error(seq, &self.no_session_error_message(&trace_path_str));
                return Ok(());
            }
        };

        // Reset TTL for this trace (navigation counts as activity).
        self.reset_ttl_for_backend_id(backend_id);

        // Map method to DAP command.
        let (dap_command, _is_custom) = match python_bridge::method_to_dap_command(&method) {
            Some(cmd) => cmd,
            None => {
                self.send_py_error(seq, &format!("unknown navigation method: {method}"));
                return Ok(());
            }
        };

        // Build DAP request arguments (`goto_ticks` carries the ticks,
        // `goto_geid` the geid; an invalid geid is refused, not defaulted).
        let dap_args = match python_bridge::navigation_dap_arguments(&method, args) {
            Ok(dap_args) => dap_args,
            Err(message) => {
                self.send_py_error(seq, &message);
                return Ok(());
            }
        };

        // Get a unique seq for the DAP command sent to the backend.
        let dap_seq = match self.daemon_state.as_mut() {
            Some(ds) => ds.py_bridge.next_seq(),
            None => return Ok(()),
        };

        // Build and send the DAP command to the backend.
        let dap_request = serde_json::json!({
            "type": "request",
            "command": dap_command,
            "seq": dap_seq,
            "arguments": dap_args,
        });

        if let Err(e) = self.message(backend_id, dap_request).await {
            self.send_py_error(seq, &format!("failed to send command to backend: {e}"));
            return Ok(());
        }

        // Look up the client that sent this request.
        let client_id = self.lookup_client_for_seq(seq).unwrap_or(0);

        // Register the pending navigation.  The response router in
        // `route_daemon_message` will advance this through the state
        // machine as the backend responds.
        if let Some(ds) = self.daemon_state.as_mut() {
            ds.py_bridge
                .pending_navigations
                .push(python_bridge::PendingPyNavigation {
                    backend_id,
                    client_id,
                    original_seq: seq,
                    state: PendingPyNavState::AwaitingStopped,
                    stack_trace_seq: None,
                    nav_command_seq: Some(dap_seq),
                    rr_ticks: None,
                    end_of_trace: false,
                    not_reached: None,
                });
        }

        Ok(())
    }

    /// Sends a Python bridge error response to the originating client.
    fn send_py_error(&self, seq: i64, message: &str) {
        let response = serde_json::json!({
            "type": "response",
            "request_seq": seq,
            "success": false,
            "command": "ct/py-navigate",
            "message": message,
        });
        let client_id = self.lookup_client_for_seq(seq);
        if self.daemon_state.is_some() {
            if let Some(cid) = client_id {
                self.send_to_client(cid, response);
            }
        } else {
            self.send_manager_message(response);
        }
    }

    // -----------------------------------------------------------------------
    // ct/py-locals, ct/py-evaluate, ct/py-stack-trace handlers
    // -----------------------------------------------------------------------

    /// Sends a Python bridge error response to the originating client.
    ///
    /// Generalized version of `send_py_error` that accepts the command name
    /// to use in the response.
    fn send_py_command_error(&self, seq: i64, command: &str, message: &str) {
        let response = serde_json::json!({
            "type": "response",
            "request_seq": seq,
            "success": false,
            "command": command,
            "message": message,
        });
        let client_id = self.lookup_client_for_seq(seq);
        if self.daemon_state.is_some() {
            if let Some(cid) = client_id {
                self.send_to_client(cid, response);
            }
        } else {
            self.send_manager_message(response);
        }
    }

    /// Looks up the backend ID for a given trace path from the session
    /// manager.  Returns `None` if not in daemon mode or the trace has
    /// no active session.
    fn backend_id_for_trace(&self, session: &SessionKey) -> Option<usize> {
        self.daemon_state
            .as_ref()
            .and_then(|ds| ds.session_manager.get_session_backend_id(session))
    }

    /// Builds an actionable error message for "no session loaded" errors.
    ///
    /// Instead of a bare "no session loaded" string, this includes the
    /// configured idle timeout and a hint to call `open_trace()` again.
    /// This helps automated agents (and humans) understand *why* the
    /// session is gone and what to do about it (issue #455).
    fn no_session_error_message(&self, trace_path: &str) -> String {
        let ttl_secs = self
            .daemon_state
            .as_ref()
            .map(|ds| ds.session_manager.default_ttl().as_secs())
            .unwrap_or(300);
        format!(
            "no session loaded for {trace_path}. \
             The session may have expired (idle timeout: {ttl_secs}s). \
             Call open_trace() to start a new session."
        )
    }

    /// Handles `ct/py-locals` requests from Python clients.
    ///
    /// Translates the request into a `ct/load-locals` DAP command, sends it
    /// to the backend, and registers a pending request that will be
    /// completed when the backend responds.
    ///
    /// # Wire protocol
    ///
    /// **Request:**
    /// ```json
    /// {
    ///   "type": "request",
    ///   "command": "ct/py-locals",
    ///   "seq": 1,
    ///   "arguments": {
    ///     "tracePath": "/path/to/trace",
    ///     "depth": 3,
    ///     "countBudget": 3000
    ///   }
    /// }
    /// ```
    ///
    /// **Response:**
    /// ```json
    /// {
    ///   "type": "response",
    ///   "request_seq": 1,
    ///   "success": true,
    ///   "command": "ct/py-locals",
    ///   "body": {
    ///     "variables": [{"name": "x", "value": "42", "type": "int", "children": []}, ...]
    ///   }
    /// }
    /// ```
    async fn handle_py_locals(
        &mut self,
        seq: i64,
        args: Option<&Value>,
    ) -> Result<(), Box<dyn Error>> {
        let trace_path_str = match args
            .and_then(|a| a.get("tracePath"))
            .and_then(Value::as_str)
        {
            Some(p) => p.to_string(),
            None => {
                self.send_py_command_error(seq, "ct/py-locals", "missing 'tracePath' in arguments");
                return Ok(());
            }
        };

        let session = SessionKey::for_request(&trace_path_str, args);

        let backend_id = match self.backend_id_for_trace(&session) {
            Some(id) => id,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-locals",
                    &self.no_session_error_message(&trace_path_str),
                );
                return Ok(());
            }
        };

        // Reset TTL for this trace (inspection counts as activity).
        self.reset_ttl_for_backend_id(backend_id);

        // Extract parameters with sensible defaults.
        //
        // The backend's `CtLoadLocalsArguments` struct expects:
        //   rrTicks, countBudget, minCountLimit, lang, watchExpressions, depthLimit
        // The Python client may send a simpler set; we fill in defaults for
        // any missing fields.
        let count_budget = args
            .and_then(|a| a.get("countBudget"))
            .and_then(Value::as_i64)
            .unwrap_or(3000);
        let depth_limit = args
            .and_then(|a| a.get("depth"))
            .and_then(Value::as_i64)
            .unwrap_or(3);
        let rr_ticks = args
            .and_then(|a| a.get("rrTicks"))
            .and_then(Value::as_i64)
            .unwrap_or(0);
        let min_count_limit = args
            .and_then(|a| a.get("minCountLimit"))
            .and_then(Value::as_i64)
            .unwrap_or(0);
        // The language by its `Lang::wire_name` (LRS-1).  The db-backend
        // decodes this field with `ct-lang`'s `lang_wire` adapter and refuses
        // an integer, so an ordinal is not passed through even if a client
        // sends one; the default is `LOAD_LOCALS_DEFAULT_LANG` (`"c"`, the
        // name of `Lang::C`), which is what the integer `0` this used to
        // forward decoded to.  The Python client does not send the field at
        // all (`python-api/codetracer/trace.py`).
        let lang = args
            .and_then(|a| a.get("lang"))
            .and_then(Value::as_str)
            .unwrap_or(LOAD_LOCALS_DEFAULT_LANG)
            .to_owned();

        // Get a unique seq for the DAP command sent to the backend.
        let dap_seq = match self.daemon_state.as_mut() {
            Some(ds) => ds.py_bridge.next_seq(),
            None => return Ok(()),
        };

        // Build and send the ct/load-locals command to the backend.
        //
        // The arguments must match the backend's `CtLoadLocalsArguments`
        // schema (camelCase):
        //   https://github.com/nicholasgasior/codetracer/blob/main/codetracer/src/replay-server/src/task.rs
        let dap_request = serde_json::json!({
            "type": "request",
            "command": "ct/load-locals",
            "seq": dap_seq,
            "arguments": {
                "rrTicks": rr_ticks,
                "countBudget": count_budget,
                "minCountLimit": min_count_limit,
                "lang": lang,
                "watchExpressions": [],
                "depthLimit": depth_limit,
            },
        });

        if let Err(e) = self.message(backend_id, dap_request).await {
            self.send_py_command_error(
                seq,
                "ct/py-locals",
                &format!("failed to send command to backend: {e}"),
            );
            return Ok(());
        }

        // Register the pending request.
        let client_id = self.lookup_client_for_seq(seq).unwrap_or(0);
        if let Some(ds) = self.daemon_state.as_mut() {
            ds.py_bridge.pending_requests.push(PendingPyRequest {
                kind: PendingPyRequestKind::Locals,
                client_id,
                original_seq: seq,
                backend_seq: dap_seq,
                response_command: "ct/py-locals".to_string(),
                expression: String::new(),
            });
        }

        Ok(())
    }

    /// Handles `ct/py-evaluate` requests from Python clients.
    ///
    /// The backend does not support the standard DAP `evaluate` command
    /// directly, so this handler implements expression evaluation by
    /// sending a `ct/load-locals` request with the expression included
    /// in `watchExpressions`.  The backend returns all locals (plus
    /// any watch expressions it can resolve), and the response formatter
    /// searches the result for the requested expression.
    ///
    /// # Wire protocol
    ///
    /// **Request:**
    /// ```json
    /// {
    ///   "type": "request",
    ///   "command": "ct/py-evaluate",
    ///   "seq": 1,
    ///   "arguments": {
    ///     "tracePath": "/path/to/trace",
    ///     "expression": "x + y"
    ///   }
    /// }
    /// ```
    ///
    /// **Response (success):**
    /// ```json
    /// {
    ///   "type": "response",
    ///   "request_seq": 1,
    ///   "success": true,
    ///   "command": "ct/py-evaluate",
    ///   "body": {"result": "30", "type": "int"}
    /// }
    /// ```
    ///
    /// **Response (failure):**
    /// ```json
    /// {
    ///   "type": "response",
    ///   "request_seq": 1,
    ///   "success": false,
    ///   "command": "ct/py-evaluate",
    ///   "message": "cannot evaluate: nonexistent_var"
    /// }
    /// ```
    async fn handle_py_evaluate(
        &mut self,
        seq: i64,
        args: Option<&Value>,
    ) -> Result<(), Box<dyn Error>> {
        let trace_path_str = match args
            .and_then(|a| a.get("tracePath"))
            .and_then(Value::as_str)
        {
            Some(p) => p.to_string(),
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-evaluate",
                    "missing 'tracePath' in arguments",
                );
                return Ok(());
            }
        };

        let expression = match args
            .and_then(|a| a.get("expression"))
            .and_then(Value::as_str)
        {
            Some(e) => e.to_string(),
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-evaluate",
                    "missing 'expression' in arguments",
                );
                return Ok(());
            }
        };

        let session = SessionKey::for_request(&trace_path_str, args);

        let backend_id = match self.backend_id_for_trace(&session) {
            Some(id) => id,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-evaluate",
                    &self.no_session_error_message(&trace_path_str),
                );
                return Ok(());
            }
        };

        // Reset TTL for this trace.
        self.reset_ttl_for_backend_id(backend_id);

        // Get a unique seq for the DAP command.
        let dap_seq = match self.daemon_state.as_mut() {
            Some(ds) => ds.py_bridge.next_seq(),
            None => return Ok(()),
        };

        // Build and send the ct/load-locals command with the expression
        // included in watchExpressions.  The backend does not support
        // the standard DAP `evaluate` command, but `ct/load-locals`
        // returns all locals at the current execution point.  By
        // including the expression in watchExpressions, it may also
        // be explicitly evaluated (for backends that support it).
        // The response formatter will search the returned locals for
        // the requested expression.
        let dap_request = serde_json::json!({
            "type": "request",
            "command": "ct/load-locals",
            "seq": dap_seq,
            "arguments": {
                "rrTicks": 0,
                "countBudget": 3000,
                "minCountLimit": 0,
                // By name, never an ordinal (LRS-1); `"c"` is what `0` meant.
                "lang": LOAD_LOCALS_DEFAULT_LANG,
                "watchExpressions": [expression],
                "depthLimit": 3,
            },
        });

        if let Err(e) = self.message(backend_id, dap_request).await {
            self.send_py_command_error(
                seq,
                "ct/py-evaluate",
                &format!("failed to send command to backend: {e}"),
            );
            return Ok(());
        }

        // Register the pending request.
        let client_id = self.lookup_client_for_seq(seq).unwrap_or(0);
        if let Some(ds) = self.daemon_state.as_mut() {
            ds.py_bridge.pending_requests.push(PendingPyRequest {
                kind: PendingPyRequestKind::Evaluate,
                client_id,
                original_seq: seq,
                backend_seq: dap_seq,
                response_command: "ct/py-evaluate".to_string(),
                expression: expression.clone(),
            });
        }

        Ok(())
    }

    /// Handles `ct/py-stack-trace` requests from Python clients.
    ///
    /// Translates the request into a DAP `stackTrace` command, sends it to
    /// the backend, and registers a pending request.
    ///
    /// # Wire protocol
    ///
    /// **Request:**
    /// ```json
    /// {
    ///   "type": "request",
    ///   "command": "ct/py-stack-trace",
    ///   "seq": 1,
    ///   "arguments": {
    ///     "tracePath": "/path/to/trace"
    ///   }
    /// }
    /// ```
    ///
    /// **Response:**
    /// ```json
    /// {
    ///   "type": "response",
    ///   "request_seq": 1,
    ///   "success": true,
    ///   "command": "ct/py-stack-trace",
    ///   "body": {
    ///     "frames": [
    ///       {"id": 0, "name": "main", "location": {"path": "main.nim", "line": 42, "column": 1}},
    ///       ...
    ///     ]
    ///   }
    /// }
    /// ```
    async fn handle_py_stack_trace(
        &mut self,
        seq: i64,
        args: Option<&Value>,
    ) -> Result<(), Box<dyn Error>> {
        let trace_path_str = match args
            .and_then(|a| a.get("tracePath"))
            .and_then(Value::as_str)
        {
            Some(p) => p.to_string(),
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-stack-trace",
                    "missing 'tracePath' in arguments",
                );
                return Ok(());
            }
        };

        let session = SessionKey::for_request(&trace_path_str, args);

        let backend_id = match self.backend_id_for_trace(&session) {
            Some(id) => id,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-stack-trace",
                    &self.no_session_error_message(&trace_path_str),
                );
                return Ok(());
            }
        };

        // Reset TTL for this trace.
        self.reset_ttl_for_backend_id(backend_id);

        // Get a unique seq for the DAP command.
        let dap_seq = match self.daemon_state.as_mut() {
            Some(ds) => ds.py_bridge.next_seq(),
            None => return Ok(()),
        };

        // Build and send the DAP stackTrace command.
        let dap_request = serde_json::json!({
            "type": "request",
            "command": "stackTrace",
            "seq": dap_seq,
            "arguments": {
                "threadId": 1,
            },
        });

        if let Err(e) = self.message(backend_id, dap_request).await {
            self.send_py_command_error(
                seq,
                "ct/py-stack-trace",
                &format!("failed to send command to backend: {e}"),
            );
            return Ok(());
        }

        // Register the pending request.
        let client_id = self.lookup_client_for_seq(seq).unwrap_or(0);
        if let Some(ds) = self.daemon_state.as_mut() {
            ds.py_bridge.pending_requests.push(PendingPyRequest {
                kind: PendingPyRequestKind::StackTrace,
                client_id,
                original_seq: seq,
                backend_seq: dap_seq,
                response_command: "ct/py-stack-trace".to_string(),
                expression: String::new(),
            });
        }

        Ok(())
    }

    // -----------------------------------------------------------------------
    // ct/py-flow handler
    // -----------------------------------------------------------------------

    /// Handles `ct/py-flow` requests from Python clients.
    ///
    /// Translates the simplified Python request into a `ct/load-flow` DAP
    /// command with proper `CtLoadFlowArguments` format (`flowMode` integer
    /// + `location` object), then sends it to the backend.
    ///
    /// Unlike most DAP commands, the backend's flow handler does NOT send
    /// a response.  Instead, it emits a `ct/updated-flow` event containing
    /// the flow data.  The daemon intercepts this event in
    /// `route_daemon_message` and converts it into a `ct/py-flow` response.
    ///
    /// Flow (omniscience) is CodeTracer's signature feature: it shows all
    /// variable values across execution of a function or a specific line.
    ///
    /// # Wire protocol
    ///
    /// **Request:**
    /// ```json
    /// {
    ///   "type": "request",
    ///   "command": "ct/py-flow",
    ///   "seq": 1,
    ///   "arguments": {
    ///     "tracePath": "/path/to/trace",
    ///     "path": "main.nim",
    ///     "line": 10,
    ///     "mode": "call",
    ///     "rrTicks": 12345
    ///   }
    /// }
    /// ```
    ///
    /// **Response** (converted from backend's `ct/updated-flow` event):
    /// ```json
    /// {
    ///   "type": "response",
    ///   "request_seq": 1,
    ///   "success": true,
    ///   "command": "ct/py-flow",
    ///   "body": {
    ///     "steps": [
    ///       {"position": 10, "rrTicks": 100, "loop": 1, "iteration": 0,
    ///        "beforeValues": {"i": "0"}, "afterValues": {"x": "0"}}
    ///     ],
    ///     "loops": [
    ///       {"base": 0, "first": 8, "last": 12, "iteration": 5, ...}
    ///     ]
    ///   }
    /// }
    /// ```
    async fn handle_py_flow(
        &mut self,
        seq: i64,
        args: Option<&Value>,
    ) -> Result<(), Box<dyn Error>> {
        let trace_path_str = match args
            .and_then(|a| a.get("tracePath"))
            .and_then(Value::as_str)
        {
            Some(p) => p.to_string(),
            None => {
                self.send_py_command_error(seq, "ct/py-flow", "missing 'tracePath' in arguments");
                return Ok(());
            }
        };

        let session = SessionKey::for_request(&trace_path_str, args);

        let backend_id = match self.backend_id_for_trace(&session) {
            Some(id) => id,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-flow",
                    &self.no_session_error_message(&trace_path_str),
                );
                return Ok(());
            }
        };

        // Reset TTL for this trace (flow query counts as activity).
        self.reset_ttl_for_backend_id(backend_id);

        // Extract path, line, mode, and rrTicks parameters from the Python
        // client's simplified request format.
        let source_path = args
            .and_then(|a| a.get("path"))
            .and_then(Value::as_str)
            .unwrap_or("");
        let line = args
            .and_then(|a| a.get("line"))
            .and_then(Value::as_i64)
            .unwrap_or(1);
        let mode = args
            .and_then(|a| a.get("mode"))
            .and_then(Value::as_str)
            .unwrap_or("call");
        let rr_ticks = args
            .and_then(|a| a.get("rrTicks"))
            .and_then(Value::as_i64)
            .unwrap_or(0);

        // Map the string mode to the integer FlowMode expected by the
        // backend's CtLoadFlowArguments.  FlowMode is serialized as a
        // repr(u8) integer: 0 = Call, 1 = Diff.
        // See: replay-server/src/task.rs — `enum FlowMode`
        let flow_mode: u8 = match mode {
            "diff" => 1,
            _ => 0, // "call" or any unrecognized mode defaults to Call
        };

        // Get a unique seq for the DAP command sent to the backend.
        let dap_seq = match self.daemon_state.as_mut() {
            Some(ds) => ds.py_bridge.next_seq(),
            None => return Ok(()),
        };

        // Build the ct/load-flow command with the correct
        // `CtLoadFlowArguments` schema that the backend expects:
        //   - `flowMode`: integer (0=Call, 1=Diff)
        //   - `location`: a Location object with at minimum `path`, `line`,
        //     and `rrTicks`.  All other Location fields use defaults.
        //
        // The backend deserializes these via `req.load_args::<CtLoadFlowArguments>()`
        // with `#[serde(rename_all = "camelCase")]`.
        //
        // See: replay-server/src/task.rs — `CtLoadFlowArguments`, `Location`
        let dap_request = serde_json::json!({
            "type": "request",
            "command": "ct/load-flow",
            "seq": dap_seq,
            "arguments": {
                "flowMode": flow_mode,
                "location": {
                    "path": source_path,
                    "line": line,
                    "functionName": "",
                    "highLevelPath": "",
                    "highLevelLine": 0,
                    "highLevelFunctionName": "",
                    "lowLevelPath": "",
                    "lowLevelLine": 0,
                    "rrTicks": rr_ticks,
                    "functionFirst": 0,
                    "functionLast": 0,
                    "event": 0,
                    "expression": "",
                    "offset": 0,
                    "error": false,
                    "callstackDepth": 0,
                    "originatingInstructionAddress": 0,
                    "key": "",
                    "globalCallKey": "",
                    "expansionParents": [],
                    "missingPath": false,
                },
            },
        });

        if let Err(e) = self.message(backend_id, dap_request).await {
            self.send_py_command_error(
                seq,
                "ct/py-flow",
                &format!("failed to send command to backend: {e}"),
            );
            return Ok(());
        }

        // Register the pending request.
        let client_id = self.lookup_client_for_seq(seq).unwrap_or(0);
        if let Some(ds) = self.daemon_state.as_mut() {
            ds.py_bridge.pending_requests.push(PendingPyRequest {
                kind: PendingPyRequestKind::Flow,
                client_id,
                original_seq: seq,
                backend_seq: dap_seq,
                response_command: "ct/py-flow".to_string(),
                expression: String::new(),
            });
        }

        Ok(())
    }

    // -----------------------------------------------------------------------
    // ct/py-add-breakpoint, ct/py-remove-breakpoint,
    // ct/py-add-watchpoint, ct/py-remove-watchpoint handlers
    // -----------------------------------------------------------------------

    /// Handles `ct/py-add-breakpoint` requests from Python clients.
    ///
    /// Adds a breakpoint to the per-trace breakpoint state, sends a
    /// `setBreakpoints` command to the backend, and answers the client
    /// only once the backend has said whether the breakpoint BOUND.
    ///
    /// The wait is the point.  `setBreakpoints` answers `success: true`
    /// even when it could not place a breakpoint — an unplaceable one is
    /// reported per-line as `verified: false` with a `message`.  While
    /// this handler fired and forgot, that verdict was discarded and the
    /// client was told `success: true` with an id before the backend had
    /// seen the request, so a breakpoint on a path the trace never
    /// recorded looked identical to one that bound, and the caller's
    /// next `continue` simply ran to the end of the trace.
    ///
    /// A rejected breakpoint is also dropped from the daemon's own table
    /// (see [`python_bridge::BreakpointState::forget_breakpoint`]) so it
    /// is not re-sent with the next add for the same file.
    ///
    /// # Wire protocol
    ///
    /// **Request:**
    /// ```json
    /// {
    ///   "type": "request",
    ///   "command": "ct/py-add-breakpoint",
    ///   "seq": 1,
    ///   "arguments": {
    ///     "tracePath": "/path/to/trace",
    ///     "path": "main.nim",
    ///     "line": 10
    ///   }
    /// }
    /// ```
    ///
    /// **Response (bound):**
    /// ```json
    /// {
    ///   "type": "response",
    ///   "request_seq": 1,
    ///   "success": true,
    ///   "command": "ct/py-add-breakpoint",
    ///   "body": {"breakpointId": 1}
    /// }
    /// ```
    ///
    /// **Response (not bound)** — carries the backend's own reason, which
    /// is what tells a typo apart from a missing recording:
    /// ```json
    /// {
    ///   "type": "response",
    ///   "request_seq": 1,
    ///   "success": false,
    ///   "command": "ct/py-add-breakpoint",
    ///   "message": "failed to set breakpoint at other.nim:10: can't add a
    ///               breakpoint: can't find path `other.nim` in trace"
    /// }
    /// ```
    async fn handle_py_add_breakpoint(
        &mut self,
        seq: i64,
        args: Option<&Value>,
    ) -> Result<(), Box<dyn Error>> {
        let trace_path_str = match args
            .and_then(|a| a.get("tracePath"))
            .and_then(Value::as_str)
        {
            Some(p) => p.to_string(),
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-add-breakpoint",
                    "missing 'tracePath' in arguments",
                );
                return Ok(());
            }
        };

        let source_path = match args.and_then(|a| a.get("path")).and_then(Value::as_str) {
            Some(p) => p.to_string(),
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-add-breakpoint",
                    "missing 'path' in arguments",
                );
                return Ok(());
            }
        };

        let line = match args.and_then(|a| a.get("line")).and_then(Value::as_i64) {
            Some(l) => l,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-add-breakpoint",
                    "missing 'line' in arguments",
                );
                return Ok(());
            }
        };

        let session = SessionKey::for_request(&trace_path_str, args);

        let backend_id = match self.backend_id_for_trace(&session) {
            Some(id) => id,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-add-breakpoint",
                    &self.no_session_error_message(&trace_path_str),
                );
                return Ok(());
            }
        };

        self.reset_ttl_for_backend_id(backend_id);

        // Update the breakpoint state and get the full list for the file.
        // `index` is where this breakpoint's verdict will sit in the
        // backend's per-line `setBreakpoints` response.
        let (bp_id, all_lines, index) = match self.daemon_state.as_mut() {
            Some(ds) => {
                let bp_state = ds.py_bridge.breakpoint_state_mut(&session);
                bp_state.add_breakpoint(&source_path, line)
            }
            None => return Ok(()),
        };

        // Build the setBreakpoints DAP command with ALL breakpoints for this file.
        let breakpoints_array: Vec<Value> = all_lines.iter().map(|l| json!({"line": l})).collect();

        let dap_seq = match self.daemon_state.as_mut() {
            Some(ds) => ds.py_bridge.next_seq(),
            None => return Ok(()),
        };

        let dap_request = json!({
            "type": "request",
            "command": "setBreakpoints",
            "seq": dap_seq,
            "arguments": {
                "source": {"path": source_path},
                "breakpoints": breakpoints_array,
            }
        });

        // Wait for the backend.  This used to be fire-and-forget: the
        // handler answered `success: true` with a breakpoint id before
        // the backend had even seen the request, and the response router
        // then dropped the backend's answer on the `FireAndForget` arm.
        // That answer is the only place the backend says whether the
        // breakpoint BOUND — `setBreakpoints` reports an unplaceable
        // breakpoint as `verified: false` with a reason, not as a failed
        // request.  Discarding it meant `Trace.add_breakpoint()` returned
        // an id for a breakpoint registered nowhere but in the daemon's
        // own table, and the next `continue_forward()` ran to the end of
        // the trace and raised `StopIteration: Reached end of trace` with
        // nothing in the API's output to explain it.
        if let Err(e) = self.message(backend_id, dap_request).await {
            // Roll back: nothing was sent, so the daemon must not keep a
            // breakpoint the backend has never heard of.
            if let Some(ds) = self.daemon_state.as_mut() {
                ds.py_bridge
                    .breakpoint_state_mut(&session)
                    .forget_breakpoint(bp_id);
            }
            self.send_py_command_error(
                seq,
                "ct/py-add-breakpoint",
                &format!("failed to send command to backend: {e}"),
            );
            return Ok(());
        }

        let client_id = self.lookup_client_for_seq(seq).unwrap_or(0);
        if let Some(ds) = self.daemon_state.as_mut() {
            ds.py_bridge.pending_requests.push(PendingPyRequest {
                kind: PendingPyRequestKind::AddBreakpoint {
                    session,
                    bp_id,
                    index,
                },
                client_id,
                original_seq: seq,
                backend_seq: dap_seq,
                response_command: "ct/py-add-breakpoint".to_string(),
                expression: String::new(),
            });
        }

        Ok(())
    }

    /// Handles `ct/py-remove-breakpoint` requests from Python clients.
    ///
    /// Removes the breakpoint from the per-trace state, sends an updated
    /// `setBreakpoints` to the backend (fire-and-forget), and returns
    /// a success response.
    ///
    /// # Wire protocol
    ///
    /// **Request:**
    /// ```json
    /// {
    ///   "type": "request",
    ///   "command": "ct/py-remove-breakpoint",
    ///   "seq": 2,
    ///   "arguments": {
    ///     "tracePath": "/path/to/trace",
    ///     "breakpointId": 1
    ///   }
    /// }
    /// ```
    ///
    /// **Response:**
    /// ```json
    /// {
    ///   "type": "response",
    ///   "request_seq": 2,
    ///   "success": true,
    ///   "command": "ct/py-remove-breakpoint",
    ///   "body": {"removed": true}
    /// }
    /// ```
    async fn handle_py_remove_breakpoint(
        &mut self,
        seq: i64,
        args: Option<&Value>,
    ) -> Result<(), Box<dyn Error>> {
        let trace_path_str = match args
            .and_then(|a| a.get("tracePath"))
            .and_then(Value::as_str)
        {
            Some(p) => p.to_string(),
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-remove-breakpoint",
                    "missing 'tracePath' in arguments",
                );
                return Ok(());
            }
        };

        let bp_id = match args
            .and_then(|a| a.get("breakpointId"))
            .and_then(Value::as_i64)
        {
            Some(id) => id,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-remove-breakpoint",
                    "missing 'breakpointId' in arguments",
                );
                return Ok(());
            }
        };

        let session = SessionKey::for_request(&trace_path_str, args);

        let backend_id = match self.backend_id_for_trace(&session) {
            Some(id) => id,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-remove-breakpoint",
                    &self.no_session_error_message(&trace_path_str),
                );
                return Ok(());
            }
        };

        self.reset_ttl_for_backend_id(backend_id);

        // Remove the breakpoint and get remaining lines for the affected file.
        let removal_result = match self.daemon_state.as_mut() {
            Some(ds) => {
                let bp_state = ds.py_bridge.breakpoint_state_mut(&session);
                bp_state.remove_breakpoint(bp_id)
            }
            None => return Ok(()),
        };

        match removal_result {
            Some((source_path, remaining_lines)) => {
                // Send updated setBreakpoints to backend with remaining lines.
                let breakpoints_array: Vec<Value> =
                    remaining_lines.iter().map(|l| json!({"line": l})).collect();

                let dap_seq = match self.daemon_state.as_mut() {
                    Some(ds) => ds.py_bridge.next_seq(),
                    None => return Ok(()),
                };

                let dap_request = json!({
                    "type": "request",
                    "command": "setBreakpoints",
                    "seq": dap_seq,
                    "arguments": {
                        "source": {"path": source_path},
                        "breakpoints": breakpoints_array,
                    }
                });
                let _ = self.message(backend_id, dap_request).await;
                if let Some(ds) = self.daemon_state.as_mut() {
                    ds.py_bridge.pending_requests.push(PendingPyRequest {
                        kind: PendingPyRequestKind::Unobserved(
                            python_bridge::UnobservedReason::SetPointsResyncAfterRemoval,
                        ),
                        client_id: 0,
                        original_seq: 0,
                        backend_seq: dap_seq,
                        response_command: String::new(),
                        expression: String::new(),
                    });
                }

                let response = json!({
                    "type": "response",
                    "request_seq": seq,
                    "success": true,
                    "command": "ct/py-remove-breakpoint",
                    "body": {"removed": true}
                });
                self.send_response_for_seq(seq, response);
            }
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-remove-breakpoint",
                    &format!("unknown breakpoint ID: {bp_id}"),
                );
            }
        }

        Ok(())
    }

    /// Handles `ct/py-add-watchpoint` requests from Python clients.
    ///
    /// Adds a watchpoint on the given expression, sends `setDataBreakpoints`
    /// to the backend (fire-and-forget), and returns the watchpoint ID.
    ///
    /// # Wire protocol
    ///
    /// **Request:**
    /// ```json
    /// {
    ///   "type": "request",
    ///   "command": "ct/py-add-watchpoint",
    ///   "seq": 1,
    ///   "arguments": {
    ///     "tracePath": "/path/to/trace",
    ///     "expression": "counter"
    ///   }
    /// }
    /// ```
    ///
    /// **Response:**
    /// ```json
    /// {
    ///   "type": "response",
    ///   "request_seq": 1,
    ///   "success": true,
    ///   "command": "ct/py-add-watchpoint",
    ///   "body": {"watchpointId": 1}
    /// }
    /// ```
    async fn handle_py_add_watchpoint(
        &mut self,
        seq: i64,
        args: Option<&Value>,
    ) -> Result<(), Box<dyn Error>> {
        let trace_path_str = match args
            .and_then(|a| a.get("tracePath"))
            .and_then(Value::as_str)
        {
            Some(p) => p.to_string(),
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-add-watchpoint",
                    "missing 'tracePath' in arguments",
                );
                return Ok(());
            }
        };

        let expression = match args
            .and_then(|a| a.get("expression"))
            .and_then(Value::as_str)
        {
            Some(e) => e.to_string(),
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-add-watchpoint",
                    "missing 'expression' in arguments",
                );
                return Ok(());
            }
        };

        let session = SessionKey::for_request(&trace_path_str, args);

        let backend_id = match self.backend_id_for_trace(&session) {
            Some(id) => id,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-add-watchpoint",
                    &self.no_session_error_message(&trace_path_str),
                );
                return Ok(());
            }
        };

        self.reset_ttl_for_backend_id(backend_id);

        // Update the watchpoint state.  `index` is where this
        // watchpoint's verdict will sit in the backend's per-entry
        // `setDataBreakpoints` response.
        let (wp_id, all_expressions, index) = match self.daemon_state.as_mut() {
            Some(ds) => {
                let bp_state = ds.py_bridge.breakpoint_state_mut(&session);
                bp_state.add_watchpoint(&expression)
            }
            None => return Ok(()),
        };

        // Build the setDataBreakpoints DAP command with ALL watchpoints.
        let breakpoints_array: Vec<Value> = all_expressions
            .iter()
            .map(|e| json!({"dataId": e}))
            .collect();

        let dap_seq = match self.daemon_state.as_mut() {
            Some(ds) => ds.py_bridge.next_seq(),
            None => return Ok(()),
        };

        let dap_request = json!({
            "type": "request",
            "command": "setDataBreakpoints",
            "seq": dap_seq,
            "arguments": {
                "breakpoints": breakpoints_array,
            }
        });

        // WAIT for the backend, exactly as `ct/py-add-breakpoint` does,
        // and for the same reason: the backend's answer is the only
        // place that says whether the watchpoint was accepted.
        //
        // HISTORY, because it is why this waits rather than fires and
        // forgets: the replay backend used to have NO `setDataBreakpoints`
        // arm at all, and answered the free-text
        // `command setDataBreakpoints not supported here`.  While this
        // was fire-and-forget that refusal was discarded and
        // `Trace.add_watchpoint()` returned a positive id for a
        // watchpoint nothing anywhere had accepted, after which
        // `continue_forward()` ran to the end of the trace and raised
        // `StopIteration` with nothing to explain why.
        //
        // The backend implements the command now (value-change
        // watchpoints — see the `ct-data-breakpoints` crate), so the
        // answer read here is a real per-entry verdict: `verified: true`
        // with an id, or `verified: false` with a code from that crate's
        // closed set naming which of the recording's limits was hit.
        if let Err(e) = self.message(backend_id, dap_request).await {
            // Roll back: nothing was sent, so the daemon must not keep a
            // watchpoint the backend has never heard of.
            if let Some(ds) = self.daemon_state.as_mut() {
                ds.py_bridge
                    .breakpoint_state_mut(&session)
                    .forget_watchpoint(wp_id);
            }
            self.send_py_command_error(
                seq,
                "ct/py-add-watchpoint",
                &format!("failed to send command to backend: {e}"),
            );
            return Ok(());
        }

        let client_id = self.lookup_client_for_seq(seq).unwrap_or(0);
        if let Some(ds) = self.daemon_state.as_mut() {
            ds.py_bridge.pending_requests.push(PendingPyRequest {
                kind: PendingPyRequestKind::AddWatchpoint {
                    session,
                    wp_id,
                    index,
                },
                client_id,
                original_seq: seq,
                backend_seq: dap_seq,
                response_command: "ct/py-add-watchpoint".to_string(),
                expression,
            });
        }

        Ok(())
    }

    /// Handles `ct/py-remove-watchpoint` requests from Python clients.
    ///
    /// Removes the watchpoint, sends an updated `setDataBreakpoints`
    /// to the backend (fire-and-forget), and returns a success response.
    ///
    /// # Wire protocol
    ///
    /// **Request:**
    /// ```json
    /// {
    ///   "type": "request",
    ///   "command": "ct/py-remove-watchpoint",
    ///   "seq": 2,
    ///   "arguments": {
    ///     "tracePath": "/path/to/trace",
    ///     "watchpointId": 1
    ///   }
    /// }
    /// ```
    ///
    /// **Response:**
    /// ```json
    /// {
    ///   "type": "response",
    ///   "request_seq": 2,
    ///   "success": true,
    ///   "command": "ct/py-remove-watchpoint",
    ///   "body": {"removed": true}
    /// }
    /// ```
    async fn handle_py_remove_watchpoint(
        &mut self,
        seq: i64,
        args: Option<&Value>,
    ) -> Result<(), Box<dyn Error>> {
        let trace_path_str = match args
            .and_then(|a| a.get("tracePath"))
            .and_then(Value::as_str)
        {
            Some(p) => p.to_string(),
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-remove-watchpoint",
                    "missing 'tracePath' in arguments",
                );
                return Ok(());
            }
        };

        let wp_id = match args
            .and_then(|a| a.get("watchpointId"))
            .and_then(Value::as_i64)
        {
            Some(id) => id,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-remove-watchpoint",
                    "missing 'watchpointId' in arguments",
                );
                return Ok(());
            }
        };

        let session = SessionKey::for_request(&trace_path_str, args);

        let backend_id = match self.backend_id_for_trace(&session) {
            Some(id) => id,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-remove-watchpoint",
                    &self.no_session_error_message(&trace_path_str),
                );
                return Ok(());
            }
        };

        self.reset_ttl_for_backend_id(backend_id);

        // Read the expression BEFORE removing it: if the backend
        // refuses the re-send below, this is what gets restored so the
        // daemon's table and the replay engine still agree.
        let (removed_expression, removal_result) = match self.daemon_state.as_mut() {
            Some(ds) => {
                let bp_state = ds.py_bridge.breakpoint_state_mut(&session);
                let expression = bp_state.watchpoint_expression(wp_id);
                (expression, bp_state.remove_watchpoint(wp_id))
            }
            None => return Ok(()),
        };

        match removal_result {
            Some(remaining_expressions) => {
                let breakpoints_array: Vec<Value> = remaining_expressions
                    .iter()
                    .map(|e| json!({"dataId": e}))
                    .collect();

                let dap_seq = match self.daemon_state.as_mut() {
                    Some(ds) => ds.py_bridge.next_seq(),
                    None => return Ok(()),
                };

                let dap_request = json!({
                    "type": "request",
                    "command": "setDataBreakpoints",
                    "seq": dap_seq,
                    "arguments": {
                        "breakpoints": breakpoints_array,
                    }
                });
                // WAIT for the backend rather than answering ahead of
                // it.  This used to be an `Unobserved` fire-and-forget,
                // justified by the fact that no watchpoint ever bound —
                // the backend had no `setDataBreakpoints` arm at all —
                // so none could fail to be removed.  That justification
                // expired the moment watchpoints started working: a
                // refused re-send now leaves a live watchpoint in the
                // replay engine while the client has been told
                // `removed: true`, and the caller's next
                // `continue_forward()` stops somewhere it has no reason
                // to expect.
                if let Err(e) = self.message(backend_id, dap_request).await {
                    // The re-send never reached the backend, so the
                    // engine still holds the watchpoint.  Put it back
                    // and say so.
                    if let (Some(ds), Some(expression)) =
                        (self.daemon_state.as_mut(), removed_expression.as_ref())
                    {
                        ds.py_bridge
                            .breakpoint_state_mut(&session)
                            .restore_watchpoint(wp_id, expression);
                    }
                    self.send_py_command_error(
                        seq,
                        "ct/py-remove-watchpoint",
                        &format!("could not send the watchpoint removal to the backend: {e}"),
                    );
                    return Ok(());
                }
                let client_id = self.lookup_client_for_seq(seq).unwrap_or(0);
                if let Some(ds) = self.daemon_state.as_mut() {
                    ds.py_bridge.pending_requests.push(PendingPyRequest {
                        kind: PendingPyRequestKind::RemoveWatchpoint {
                            session: session.clone(),
                            wp_id,
                            expression: removed_expression.unwrap_or_default(),
                        },
                        client_id,
                        original_seq: seq,
                        backend_seq: dap_seq,
                        response_command: "ct/py-remove-watchpoint".to_string(),
                        expression: String::new(),
                    });
                }
            }
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-remove-watchpoint",
                    &format!("unknown watchpoint ID: {wp_id}"),
                );
            }
        }

        Ok(())
    }

    // -----------------------------------------------------------------------
    // ct/py-add-tracepoint, ct/py-remove-tracepoint,
    // ct/py-run-tracepoints handlers
    // -----------------------------------------------------------------------

    /// Handles `ct/py-add-tracepoint` requests from Python clients.
    ///
    /// Stores the tracepoint in the daemon's per-trace state.  No DAP
    /// command is sent to the backend until `ct/py-run-tracepoints` is
    /// called.
    ///
    /// # Wire protocol
    ///
    /// **Request:**
    /// ```json
    /// {
    ///   "type": "request",
    ///   "command": "ct/py-add-tracepoint",
    ///   "seq": 1,
    ///   "arguments": {
    ///     "tracePath": "/path/to/trace",
    ///     "path": "main.c",
    ///     "line": 42,
    ///     "expression": "log(x, y)"
    ///   }
    /// }
    /// ```
    ///
    /// **Response:**
    /// ```json
    /// {
    ///   "type": "response",
    ///   "request_seq": 1,
    ///   "success": true,
    ///   "command": "ct/py-add-tracepoint",
    ///   "body": {"tracepointId": 1}
    /// }
    /// ```
    async fn handle_py_add_tracepoint(
        &mut self,
        seq: i64,
        args: Option<&Value>,
    ) -> Result<(), Box<dyn Error>> {
        let trace_path_str = match args
            .and_then(|a| a.get("tracePath"))
            .and_then(Value::as_str)
        {
            Some(p) => p.to_string(),
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-add-tracepoint",
                    "missing 'tracePath' in arguments",
                );
                return Ok(());
            }
        };

        let source_path = match args.and_then(|a| a.get("path")).and_then(Value::as_str) {
            Some(p) => p.to_string(),
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-add-tracepoint",
                    "missing 'path' in arguments",
                );
                return Ok(());
            }
        };

        let line = match args.and_then(|a| a.get("line")).and_then(Value::as_i64) {
            Some(l) => l,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-add-tracepoint",
                    "missing 'line' in arguments",
                );
                return Ok(());
            }
        };

        let expression = match args
            .and_then(|a| a.get("expression"))
            .and_then(Value::as_str)
        {
            Some(e) => e.to_string(),
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-add-tracepoint",
                    "missing 'expression' in arguments",
                );
                return Ok(());
            }
        };

        let session = SessionKey::for_request(&trace_path_str, args);

        // Validate that a session exists for this trace (but no DAP
        // command is sent — tracepoints are stored daemon-side until
        // ct/py-run-tracepoints).
        if self.backend_id_for_trace(&session).is_none() {
            self.send_py_command_error(
                seq,
                "ct/py-add-tracepoint",
                &self.no_session_error_message(&trace_path_str),
            );
            return Ok(());
        }

        let tp_id = match self.daemon_state.as_mut() {
            Some(ds) => {
                let bp_state = ds.py_bridge.breakpoint_state_mut(&session);
                let (tp_id, _entry) = bp_state.add_tracepoint(&source_path, line, &expression);
                tp_id
            }
            None => return Ok(()),
        };

        let response = json!({
            "type": "response",
            "request_seq": seq,
            "success": true,
            "command": "ct/py-add-tracepoint",
            "body": {"tracepointId": tp_id}
        });
        self.send_response_for_seq(seq, response);
        Ok(())
    }

    /// Handles `ct/py-remove-tracepoint` requests from Python clients.
    ///
    /// Removes the tracepoint from daemon-side state.
    ///
    /// # Wire protocol
    ///
    /// **Request:**
    /// ```json
    /// {
    ///   "type": "request",
    ///   "command": "ct/py-remove-tracepoint",
    ///   "seq": 2,
    ///   "arguments": {
    ///     "tracePath": "/path/to/trace",
    ///     "tracepointId": 1
    ///   }
    /// }
    /// ```
    ///
    /// **Response:**
    /// ```json
    /// {
    ///   "type": "response",
    ///   "request_seq": 2,
    ///   "success": true,
    ///   "command": "ct/py-remove-tracepoint",
    ///   "body": {"removed": true}
    /// }
    /// ```
    async fn handle_py_remove_tracepoint(
        &mut self,
        seq: i64,
        args: Option<&Value>,
    ) -> Result<(), Box<dyn Error>> {
        let trace_path_str = match args
            .and_then(|a| a.get("tracePath"))
            .and_then(Value::as_str)
        {
            Some(p) => p.to_string(),
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-remove-tracepoint",
                    "missing 'tracePath' in arguments",
                );
                return Ok(());
            }
        };

        let tp_id = match args
            .and_then(|a| a.get("tracepointId"))
            .and_then(Value::as_i64)
        {
            Some(id) => id,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-remove-tracepoint",
                    "missing 'tracepointId' in arguments",
                );
                return Ok(());
            }
        };

        let session = SessionKey::for_request(&trace_path_str, args);

        let removed = match self.daemon_state.as_mut() {
            Some(ds) => {
                let bp_state = ds.py_bridge.breakpoint_state_mut(&session);
                bp_state.remove_tracepoint(tp_id)
            }
            None => return Ok(()),
        };

        if removed {
            let response = json!({
                "type": "response",
                "request_seq": seq,
                "success": true,
                "command": "ct/py-remove-tracepoint",
                "body": {"removed": true}
            });
            self.send_response_for_seq(seq, response);
        } else {
            self.send_py_command_error(
                seq,
                "ct/py-remove-tracepoint",
                &format!("unknown tracepoint ID: {tp_id}"),
            );
        }

        Ok(())
    }

    /// Handles `ct/py-run-tracepoints` requests from Python clients.
    ///
    /// Builds a `ct/run-tracepoints` DAP command from all stored tracepoints
    /// and sends it to the backend's tracepoint thread.  Registers a pending
    /// request that is resolved when the backend emits a
    /// `ct/tracepoint-results` event, or, when the backend refuses the sweep
    /// (it then answers `success: false` and sends no event), by that
    /// refusal, which the client gets as `success: false` with the reason.
    ///
    /// # Wire protocol
    ///
    /// **Request:**
    /// ```json
    /// {
    ///   "type": "request",
    ///   "command": "ct/py-run-tracepoints",
    ///   "seq": 3,
    ///   "arguments": {
    ///     "tracePath": "/path/to/trace",
    ///     "limit": 100
    ///   }
    /// }
    /// ```
    ///
    /// **Response** (async, after `ct/tracepoint-results` event):
    /// ```json
    /// {
    ///   "type": "response",
    ///   "request_seq": 3,
    ///   "success": true,
    ///   "command": "ct/py-run-tracepoints",
    ///   "body": {
    ///     "results": [
    ///       {
    ///         "tracepointId": 1,
    ///         "path": "main.c",
    ///         "line": 42,
    ///         "ticks": 12345,
    ///         "iteration": 0,
    ///         "values": [{"name": "x", "value": "42"}]
    ///       }
    ///     ],
    ///     "errors": {}
    ///   }
    /// }
    /// ```
    async fn handle_py_run_tracepoints(
        &mut self,
        seq: i64,
        args: Option<&Value>,
    ) -> Result<(), Box<dyn Error>> {
        let trace_path_str = match args
            .and_then(|a| a.get("tracePath"))
            .and_then(Value::as_str)
        {
            Some(p) => p.to_string(),
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-run-tracepoints",
                    "missing 'tracePath' in arguments",
                );
                return Ok(());
            }
        };

        // THE SCRIPT'S LIMIT (Viewport-Driven-Loading, Decided Q4): `limit`
        // hits, or every hit for `null` / a negative one. `stopAfter` is the
        // older spelling of the same bound.
        let stop_after = args
            .and_then(|a| a.get("limit").or_else(|| a.get("stopAfter")))
            .map(|v| v.as_i64().unwrap_or(-1))
            .unwrap_or(-1);

        let session = SessionKey::for_request(&trace_path_str, args);

        let backend_id = match self.backend_id_for_trace(&session) {
            Some(id) => id,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-run-tracepoints",
                    &self.no_session_error_message(&trace_path_str),
                );
                return Ok(());
            }
        };

        self.reset_ttl_for_backend_id(backend_id);

        // Build the tracepoints array from daemon-side state.
        let tracepoints_json: Vec<Value> = match self.daemon_state.as_ref() {
            Some(ds) => {
                let bp_state = ds
                    .py_bridge
                    .breakpoint_states
                    .get(&session)
                    .map(|s| s.all_tracepoints())
                    .unwrap_or_default();
                bp_state
                    .into_iter()
                    .map(|(tp_id, entry)| {
                        json!({
                            "tracepointId": tp_id,
                            "mode": 0, // TracepointMode::Log
                            "line": entry.line,
                            "offset": 0,
                            "name": entry.source_path,
                            "expression": entry.expression,
                            "lastRender": 0,
                            "isDisabled": false,
                            "isChanged": false,
                            // No `lang` (LRS-1): the db-backend's `Tracepoint`
                            // has no such field any more; it never read the
                            // ordinal that used to be sent here.
                            "results": [],
                            "tracepointError": ""
                        })
                    })
                    .collect()
            }
            None => return Ok(()),
        };

        if tracepoints_json.is_empty() {
            // No tracepoints registered — return empty results immediately.
            let response = json!({
                "type": "response",
                "request_seq": seq,
                "success": true,
                "command": "ct/py-run-tracepoints",
                "body": {
                    "results": [],
                    "errors": {}
                }
            });
            self.send_response_for_seq(seq, response);
            return Ok(());
        }

        let dap_seq = match self.daemon_state.as_mut() {
            Some(ds) => ds.py_bridge.next_seq(),
            None => return Ok(()),
        };

        // Build the RunTracepointsArg-shaped DAP command.
        let dap_request = json!({
            "type": "request",
            "command": "ct/run-tracepoints",
            "seq": dap_seq,
            "arguments": {
                "session": {
                    "id": 1,
                    "tracepoints": tracepoints_json,
                    "found": [],
                    "lastCount": 0,
                    "results": {}
                },
                "stopAfter": stop_after,
                // The script reads every hit's values: they ride the
                // results event, bounded by the script's own limit (Q4).
                "withLocals": true
            }
        });

        if let Err(e) = self.message(backend_id, dap_request).await {
            self.send_py_command_error(
                seq,
                "ct/py-run-tracepoints",
                &format!("failed to send command to backend: {e}"),
            );
            return Ok(());
        }

        // Register a pending request to be resolved when the backend
        // emits the `ct/tracepoint-results` event.
        let client_id = self.lookup_client_for_seq(seq).unwrap_or(0);
        if let Some(ds) = self.daemon_state.as_mut() {
            ds.py_bridge.pending_requests.push(PendingPyRequest {
                kind: PendingPyRequestKind::RunTracepoints,
                client_id,
                original_seq: seq,
                backend_seq: dap_seq,
                response_command: "ct/py-run-tracepoints".to_string(),
                expression: String::new(),
            });
        }

        Ok(())
    }

    // -----------------------------------------------------------------------
    // ct/py-calltrace, ct/py-search-calltrace, ct/py-events,
    // ct/py-terminal, ct/py-read-source handlers
    // -----------------------------------------------------------------------

    /// Handles `ct/py-calltrace` requests from Python clients.
    ///
    /// Translates the request into a `ct/load-calltrace-section` DAP command,
    /// sends it to the backend, and registers a pending request.
    ///
    /// # Wire protocol
    ///
    /// **Request:**
    /// ```json
    /// {
    ///   "type": "request",
    ///   "command": "ct/py-calltrace",
    ///   "seq": 1,
    ///   "arguments": {
    ///     "tracePath": "/path/to/trace",
    ///     "start": 0,
    ///     "count": 20,
    ///     "depth": 10
    ///   }
    /// }
    /// ```
    ///
    /// **Response:**
    /// ```json
    /// {
    ///   "type": "response",
    ///   "request_seq": 1,
    ///   "success": true,
    ///   "command": "ct/py-calltrace",
    ///   "body": {
    ///     "calls": [{"id": 0, "name": "main", "location": {...}, ...}, ...]
    ///   }
    /// }
    /// ```
    async fn handle_py_calltrace(
        &mut self,
        seq: i64,
        args: Option<&Value>,
    ) -> Result<(), Box<dyn Error>> {
        let trace_path_str = match args
            .and_then(|a| a.get("tracePath"))
            .and_then(Value::as_str)
        {
            Some(p) => p.to_string(),
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-calltrace",
                    "missing 'tracePath' in arguments",
                );
                return Ok(());
            }
        };

        let session = SessionKey::for_request(&trace_path_str, args);

        let backend_id = match self.backend_id_for_trace(&session) {
            Some(id) => id,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-calltrace",
                    &self.no_session_error_message(&trace_path_str),
                );
                return Ok(());
            }
        };

        // Reset TTL for this trace (calltrace query counts as activity).
        self.reset_ttl_for_backend_id(backend_id);

        // Extract start, count, and depth parameters (with sensible defaults).
        let start = args
            .and_then(|a| a.get("start"))
            .and_then(Value::as_i64)
            .unwrap_or(0);
        let count = args
            .and_then(|a| a.get("count"))
            .and_then(Value::as_i64)
            .unwrap_or(20);
        let depth = args
            .and_then(|a| a.get("depth"))
            .and_then(Value::as_i64)
            .unwrap_or(10);

        // Get a unique seq for the DAP command sent to the backend.
        let dap_seq = match self.daemon_state.as_mut() {
            Some(ds) => ds.py_bridge.next_seq(),
            None => return Ok(()),
        };

        // Build and send the ct/load-calltrace-section command to the backend.
        //
        // The backend deserializes the arguments as `CalltraceLoadArgs` which
        // expects camelCase fields: `location`, `startCallLineIndex`, `depth`,
        // `height`, `rawIgnorePatterns`, `autoCollapsing`, `optimizeCollapse`,
        // and `renderCallLineIndex`.  We map the simplified Python bridge
        // parameters (`start`, `count`, `depth`) onto these fields:
        //   - `start` -> `startCallLineIndex` (the first call-line index)
        //   - `count` -> `height` (number of visible call-lines to load)
        //   - `depth` -> `depth` (maximum call nesting depth)
        //
        // See: replay-server/src/task.rs — `CalltraceLoadArgs`
        let dap_request = serde_json::json!({
            "type": "request",
            "command": "ct/load-calltrace-section",
            "seq": dap_seq,
            "arguments": {
                "location": {
                    "path": "",
                    "line": 0,
                    "functionName": "",
                    "highLevelPath": "",
                    "highLevelLine": 0,
                    "highLevelFunctionName": "",
                    "lowLevelPath": "",
                    "lowLevelLine": 0,
                    "rrTicks": 0,
                    "functionFirst": 0,
                    "functionLast": 0,
                    "event": 0,
                    "expression": "",
                    "offset": 0,
                    "error": false,
                    "callstackDepth": 0,
                    "originatingInstructionAddress": 0,
                    "key": "",
                    "globalCallKey": "",
                    "expansionParents": [],
                    "missingPath": false,
                },
                "startCallLineIndex": start,
                "depth": depth,
                "height": count,
                "rawIgnorePatterns": "",
                "autoCollapsing": false,
                "optimizeCollapse": false,
                "renderCallLineIndex": 0,
            },
        });

        if let Err(e) = self.message(backend_id, dap_request).await {
            self.send_py_command_error(
                seq,
                "ct/py-calltrace",
                &format!("failed to send command to backend: {e}"),
            );
            return Ok(());
        }

        // Register the pending request.
        let client_id = self.lookup_client_for_seq(seq).unwrap_or(0);
        if let Some(ds) = self.daemon_state.as_mut() {
            ds.py_bridge.pending_requests.push(PendingPyRequest {
                kind: PendingPyRequestKind::Calltrace,
                client_id,
                original_seq: seq,
                backend_seq: dap_seq,
                response_command: "ct/py-calltrace".to_string(),
                expression: String::new(),
            });
        }

        Ok(())
    }

    /// Handles `ct/py-search-calltrace` requests from Python clients.
    ///
    /// Translates the request into a `ct/search-calltrace` DAP command,
    /// sends it to the backend, and registers a pending request.
    ///
    /// # Wire protocol
    ///
    /// **Request:**
    /// ```json
    /// {
    ///   "type": "request",
    ///   "command": "ct/py-search-calltrace",
    ///   "seq": 1,
    ///   "arguments": {
    ///     "tracePath": "/path/to/trace",
    ///     "query": "main",
    ///     "limit": 100
    ///   }
    /// }
    /// ```
    ///
    /// **Response:**
    /// ```json
    /// {
    ///   "type": "response",
    ///   "request_seq": 1,
    ///   "success": true,
    ///   "command": "ct/py-search-calltrace",
    ///   "body": {
    ///     "calls": [{"id": 0, "name": "main", "location": {...}, ...}, ...]
    ///   }
    /// }
    /// ```
    async fn handle_py_search_calltrace(
        &mut self,
        seq: i64,
        args: Option<&Value>,
    ) -> Result<(), Box<dyn Error>> {
        let trace_path_str = match args
            .and_then(|a| a.get("tracePath"))
            .and_then(Value::as_str)
        {
            Some(p) => p.to_string(),
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-search-calltrace",
                    "missing 'tracePath' in arguments",
                );
                return Ok(());
            }
        };

        let query = args
            .and_then(|a| a.get("query"))
            .and_then(Value::as_str)
            .unwrap_or("");
        // NOTE: The backend's `CallSearchArg` does not have a `limit` field —
        // it returns all matching calls.  We preserve `_limit` here in case
        // the backend adds filtering support in the future.
        let _limit = args
            .and_then(|a| a.get("limit"))
            .and_then(Value::as_i64)
            .unwrap_or(100);

        let session = SessionKey::for_request(&trace_path_str, args);

        let backend_id = match self.backend_id_for_trace(&session) {
            Some(id) => id,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-search-calltrace",
                    &self.no_session_error_message(&trace_path_str),
                );
                return Ok(());
            }
        };

        // Reset TTL for this trace.
        self.reset_ttl_for_backend_id(backend_id);

        // Get a unique seq for the DAP command.
        let dap_seq = match self.daemon_state.as_mut() {
            Some(ds) => ds.py_bridge.next_seq(),
            None => return Ok(()),
        };

        // Build and send the ct/search-calltrace command to the backend.
        //
        // The backend deserializes the arguments as `CallSearchArg` which
        // has a single field `value` (the regex pattern to match function
        // names against).  The `limit` parameter is not part of the backend
        // struct — the backend returns all matching calls.
        //
        // See: replay-server/src/task.rs — `CallSearchArg`
        let dap_request = serde_json::json!({
            "type": "request",
            "command": "ct/search-calltrace",
            "seq": dap_seq,
            "arguments": {
                "value": query,
            },
        });

        if let Err(e) = self.message(backend_id, dap_request).await {
            self.send_py_command_error(
                seq,
                "ct/py-search-calltrace",
                &format!("failed to send command to backend: {e}"),
            );
            return Ok(());
        }

        // Register the pending request.
        let client_id = self.lookup_client_for_seq(seq).unwrap_or(0);
        if let Some(ds) = self.daemon_state.as_mut() {
            ds.py_bridge.pending_requests.push(PendingPyRequest {
                kind: PendingPyRequestKind::SearchCalltrace,
                client_id,
                original_seq: seq,
                backend_seq: dap_seq,
                response_command: "ct/py-search-calltrace".to_string(),
                expression: String::new(),
            });
        }

        Ok(())
    }

    /// Handles `ct/py-events` requests from Python clients.
    ///
    /// Translates the request into a `ct/event-load` DAP command,
    /// sends it to the backend, and registers a pending request.
    ///
    /// # Wire protocol
    ///
    /// **Request:**
    /// ```json
    /// {
    ///   "type": "request",
    ///   "command": "ct/py-events",
    ///   "seq": 1,
    ///   "arguments": {
    ///     "tracePath": "/path/to/trace",
    ///     "start": 0,
    ///     "count": 10,
    ///     "typeFilter": "stdout",
    ///     "search": null
    ///   }
    /// }
    /// ```
    ///
    /// **Response:**
    /// ```json
    /// {
    ///   "type": "response",
    ///   "request_seq": 1,
    ///   "success": true,
    ///   "command": "ct/py-events",
    ///   "body": {
    ///     "events": [{"id": 0, "type": "stdout", "ticks": 100, ...}, ...]
    ///   }
    /// }
    /// ```
    async fn handle_py_events(
        &mut self,
        seq: i64,
        args: Option<&Value>,
    ) -> Result<(), Box<dyn Error>> {
        let trace_path_str = match args
            .and_then(|a| a.get("tracePath"))
            .and_then(Value::as_str)
        {
            Some(p) => p.to_string(),
            None => {
                self.send_py_command_error(seq, "ct/py-events", "missing 'tracePath' in arguments");
                return Ok(());
            }
        };

        let session = SessionKey::for_request(&trace_path_str, args);

        let backend_id = match self.backend_id_for_trace(&session) {
            Some(id) => id,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-events",
                    &self.no_session_error_message(&trace_path_str),
                );
                return Ok(());
            }
        };

        // Reset TTL for this trace.
        self.reset_ttl_for_backend_id(backend_id);

        // Extract parameters with sensible defaults.
        let start = args
            .and_then(|a| a.get("start"))
            .and_then(Value::as_i64)
            .unwrap_or(0);
        let count = args
            .and_then(|a| a.get("count"))
            .and_then(Value::as_i64)
            .unwrap_or(100);

        // typeFilter and search are optional — pass them as-is (null if absent).
        let type_filter = args
            .and_then(|a| a.get("typeFilter"))
            .cloned()
            .unwrap_or(Value::Null);
        let search = args
            .and_then(|a| a.get("search"))
            .cloned()
            .unwrap_or(Value::Null);

        // Get a unique seq for the DAP command.
        let dap_seq = match self.daemon_state.as_mut() {
            Some(ds) => ds.py_bridge.next_seq(),
            None => return Ok(()),
        };

        // Build and send the ct/event-load command to the backend.
        let dap_request = serde_json::json!({
            "type": "request",
            "command": "ct/event-load",
            "seq": dap_seq,
            "arguments": {
                "start": start,
                "count": count,
                "typeFilter": type_filter,
                "search": search,
            },
        });

        if let Err(e) = self.message(backend_id, dap_request).await {
            self.send_py_command_error(
                seq,
                "ct/py-events",
                &format!("failed to send command to backend: {e}"),
            );
            return Ok(());
        }

        // Register the pending request.
        let client_id = self.lookup_client_for_seq(seq).unwrap_or(0);
        if let Some(ds) = self.daemon_state.as_mut() {
            ds.py_bridge.pending_requests.push(PendingPyRequest {
                kind: PendingPyRequestKind::Events,
                client_id,
                original_seq: seq,
                backend_seq: dap_seq,
                response_command: "ct/py-events".to_string(),
                expression: String::new(),
            });
        }

        Ok(())
    }

    /// Handles `ct/py-terminal` requests from Python clients.
    ///
    /// Translates the request into a `ct/load-terminal` DAP command,
    /// sends it to the backend, and registers a pending request.
    ///
    /// # Wire protocol
    ///
    /// **Request:**
    /// ```json
    /// {
    ///   "type": "request",
    ///   "command": "ct/py-terminal",
    ///   "seq": 1,
    ///   "arguments": {
    ///     "tracePath": "/path/to/trace",
    ///     "startLine": 0,
    ///     "endLine": -1
    ///   }
    /// }
    /// ```
    ///
    /// **Response:**
    /// ```json
    /// {
    ///   "type": "response",
    ///   "request_seq": 1,
    ///   "success": true,
    ///   "command": "ct/py-terminal",
    ///   "body": {
    ///     "output": "Hello, World!\nDone.\n"
    ///   }
    /// }
    /// ```
    async fn handle_py_terminal(
        &mut self,
        seq: i64,
        args: Option<&Value>,
    ) -> Result<(), Box<dyn Error>> {
        let trace_path_str = match args
            .and_then(|a| a.get("tracePath"))
            .and_then(Value::as_str)
        {
            Some(p) => p.to_string(),
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-terminal",
                    "missing 'tracePath' in arguments",
                );
                return Ok(());
            }
        };

        let session = SessionKey::for_request(&trace_path_str, args);

        let backend_id = match self.backend_id_for_trace(&session) {
            Some(id) => id,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-terminal",
                    &self.no_session_error_message(&trace_path_str),
                );
                return Ok(());
            }
        };

        // Reset TTL for this trace.
        self.reset_ttl_for_backend_id(backend_id);

        let start_line = args
            .and_then(|a| a.get("startLine"))
            .and_then(Value::as_i64)
            .unwrap_or(0);
        let end_line = args
            .and_then(|a| a.get("endLine"))
            .and_then(Value::as_i64)
            .unwrap_or(-1);

        // Get a unique seq for the DAP command.
        let dap_seq = match self.daemon_state.as_mut() {
            Some(ds) => ds.py_bridge.next_seq(),
            None => return Ok(()),
        };

        // Build and send the ct/load-terminal command to the backend.
        let dap_request = serde_json::json!({
            "type": "request",
            "command": "ct/load-terminal",
            "seq": dap_seq,
            "arguments": {
                "startLine": start_line,
                "endLine": end_line,
            },
        });

        if let Err(e) = self.message(backend_id, dap_request).await {
            self.send_py_command_error(
                seq,
                "ct/py-terminal",
                &format!("failed to send command to backend: {e}"),
            );
            return Ok(());
        }

        // Register the pending request.
        let client_id = self.lookup_client_for_seq(seq).unwrap_or(0);
        if let Some(ds) = self.daemon_state.as_mut() {
            ds.py_bridge.pending_requests.push(PendingPyRequest {
                kind: PendingPyRequestKind::Terminal,
                client_id,
                original_seq: seq,
                backend_seq: dap_seq,
                response_command: "ct/py-terminal".to_string(),
                expression: String::new(),
            });
        }

        Ok(())
    }

    /// Handles `ct/py-read-source` requests from Python clients.
    ///
    /// Translates the request into a DAP `source` request
    /// (<https://microsoft.github.io/debug-adapter-protocol/specification#Requests_Source>),
    /// sends it to the session's backend, and registers a pending request.
    /// The request carries `allowWorkingTree` from the session's host-read
    /// setting, so a session with host reads off asks the backend for the
    /// recording's own copy only; the backend applies the same rule from
    /// its own launch setting as well.
    ///
    /// # Wire protocol
    ///
    /// **Request:**
    /// ```json
    /// {
    ///   "type": "request",
    ///   "command": "ct/py-read-source",
    ///   "seq": 1,
    ///   "arguments": {
    ///     "tracePath": "/path/to/trace",
    ///     "path": "main.nim"
    ///   }
    /// }
    /// ```
    ///
    /// **Response:**
    /// ```json
    /// {
    ///   "type": "response",
    ///   "request_seq": 1,
    ///   "success": true,
    ///   "command": "ct/py-read-source",
    ///   "body": {
    ///     "content": "proc main() =\n  echo \"hello\"\n"
    ///   }
    /// }
    /// ```
    async fn handle_py_read_source(
        &mut self,
        seq: i64,
        args: Option<&Value>,
    ) -> Result<(), Box<dyn Error>> {
        let trace_path_str = match args
            .and_then(|a| a.get("tracePath"))
            .and_then(Value::as_str)
        {
            Some(p) => p.to_string(),
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-read-source",
                    "missing 'tracePath' in arguments",
                );
                return Ok(());
            }
        };

        let source_path = match args.and_then(|a| a.get("path")).and_then(Value::as_str) {
            Some(p) => p.to_string(),
            None => {
                self.send_py_command_error(seq, "ct/py-read-source", "missing 'path' in arguments");
                return Ok(());
            }
        };

        let session = SessionKey::for_request(&trace_path_str, args);

        let backend_id = match self.backend_id_for_trace(&session) {
            Some(id) => id,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-read-source",
                    &self.no_session_error_message(&trace_path_str),
                );
                return Ok(());
            }
        };

        // Reset TTL for this trace.
        self.reset_ttl_for_backend_id(backend_id);

        // Get a unique seq for the DAP command.
        let dap_seq = match self.daemon_state.as_mut() {
            Some(ds) => ds.py_bridge.next_seq(),
            None => return Ok(()),
        };

        // Build and send the DAP `source` request to the backend.
        let dap_request = serde_json::json!({
            "type": "request",
            "command": "source",
            "seq": dap_seq,
            "arguments": {
                "source": {"path": source_path},
                // Required by the DAP schema; 0 means "read by path".
                "sourceReference": 0,
                "allowWorkingTree": session.host_source_reads.is_allowed(),
            },
        });

        if let Err(e) = self.message(backend_id, dap_request).await {
            self.send_py_command_error(
                seq,
                "ct/py-read-source",
                &format!("failed to send command to backend: {e}"),
            );
            return Ok(());
        }

        // Register the pending request.
        let client_id = self.lookup_client_for_seq(seq).unwrap_or(0);
        if let Some(ds) = self.daemon_state.as_mut() {
            ds.py_bridge.pending_requests.push(PendingPyRequest {
                kind: PendingPyRequestKind::ReadSource,
                client_id,
                original_seq: seq,
                backend_seq: dap_seq,
                response_command: "ct/py-read-source".to_string(),
                expression: String::new(),
            });
        }

        Ok(())
    }

    /// Handles `ct/py-origin-chain` requests from Python clients.
    ///
    /// Backs `Trace.value_origin(...)` (M8 of the Value Origin Tracking
    /// milestones) by translating the request into the backend's
    /// `ct/originChain` DAP command and registering a pending request
    /// whose response is forwarded verbatim (spec §4.1 is the public
    /// wire contract — see
    /// [`python_bridge::format_origin_chain_response`]).
    ///
    /// Without this route the command fell through to the generic
    /// "forward to the selected replay" arm, which handed the backend a
    /// `ct/py-origin-chain` command it does not implement — so every
    /// `trace.value_origin(...)` call raised `TraceError`, and the
    /// `PendingPyRequestKind::OriginChain` arm below was unreachable.
    ///
    /// # Wire protocol
    ///
    /// **Request** (from the Python client):
    /// ```json
    /// {
    ///   "type": "request",
    ///   "command": "ct/py-origin-chain",
    ///   "seq": 1,
    ///   "arguments": {
    ///     "tracePath": "/path/to/trace",
    ///     "variableName": "total",
    ///     "maxHops": 16,
    ///     "lazy": false,
    ///     "stepId": 137,
    ///     "frameId": 0
    ///   }
    /// }
    /// ```
    ///
    /// **Response:** the backend's `OriginChain` body, unmodified.
    async fn handle_py_origin_chain(
        &mut self,
        seq: i64,
        args: Option<&Value>,
    ) -> Result<(), Box<dyn Error>> {
        let trace_path_str = match args
            .and_then(|a| a.get("tracePath"))
            .and_then(Value::as_str)
        {
            Some(p) => p.to_string(),
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-origin-chain",
                    "missing 'tracePath' in arguments",
                );
                return Ok(());
            }
        };

        let variable_name = match args
            .and_then(|a| a.get("variableName"))
            .and_then(Value::as_str)
        {
            Some(v) if !v.is_empty() => v.to_string(),
            _ => {
                self.send_py_command_error(
                    seq,
                    "ct/py-origin-chain",
                    "missing 'variableName' in arguments",
                );
                return Ok(());
            }
        };

        let session = SessionKey::for_request(&trace_path_str, args);

        let backend_id = match self.backend_id_for_trace(&session) {
            Some(id) => id,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-origin-chain",
                    &self.no_session_error_message(&trace_path_str),
                );
                return Ok(());
            }
        };

        self.reset_ttl_for_backend_id(backend_id);

        // Negative frame / step mean "topmost frame" / "current step" on
        // the backend side, which is exactly what an omitted argument
        // should mean here.
        let frame_id = args
            .and_then(|a| a.get("frameId"))
            .and_then(Value::as_i64)
            .unwrap_or(-1);
        let step_id = args
            .and_then(|a| a.get("stepId"))
            .and_then(Value::as_i64)
            .unwrap_or(-1);
        let max_hops = args
            .and_then(|a| a.get("maxHops"))
            .and_then(Value::as_u64)
            .unwrap_or(16);
        let lazy = args
            .and_then(|a| a.get("lazy"))
            .and_then(Value::as_bool)
            .unwrap_or(false);

        let dap_seq = match self.daemon_state.as_mut() {
            Some(ds) => ds.py_bridge.next_seq(),
            None => return Ok(()),
        };

        // `CtOriginChainArguments` is `#[serde(deny_unknown_fields)]`, so
        // every key here must be one of its camelCase fields — do not
        // forward the client's argument object wholesale (it carries
        // `tracePath`, which the backend would reject).
        let mut backend_args = serde_json::json!({
            "variableName": variable_name,
            "variablePath": [],
            "frameId": frame_id,
            "stepId": step_id,
            "threadId": 0,
            "maxHops": max_hops,
            "lazy": lazy,
            "sessionId": "",
            "classifySource": true,
        });
        if let Some(token) = args
            .and_then(|a| a.get("continuationToken"))
            .and_then(Value::as_str)
        {
            backend_args["continuationToken"] = serde_json::json!(token);
        }

        let dap_request = serde_json::json!({
            "type": "request",
            "command": "ct/originChain",
            "seq": dap_seq,
            "arguments": backend_args,
        });

        if let Err(e) = self.message(backend_id, dap_request).await {
            self.send_py_command_error(
                seq,
                "ct/py-origin-chain",
                &format!("failed to send command to backend: {e}"),
            );
            return Ok(());
        }

        let client_id = self.lookup_client_for_seq(seq).unwrap_or(0);
        if let Some(ds) = self.daemon_state.as_mut() {
            ds.py_bridge.pending_requests.push(PendingPyRequest {
                kind: PendingPyRequestKind::OriginChain,
                client_id,
                original_seq: seq,
                backend_seq: dap_seq,
                response_command: "ct/py-origin-chain".to_string(),
                expression: variable_name,
            });
        }

        Ok(())
    }

    // -----------------------------------------------------------------------
    // ct/py-processes, ct/py-select-process handlers
    // -----------------------------------------------------------------------

    /// Handles `ct/py-processes` requests from Python clients.
    ///
    /// Translates the request into a `ct/list-processes` DAP command, sends
    /// it to the backend, and registers a pending request that will be
    /// completed when the backend responds.
    ///
    /// # Wire protocol
    ///
    /// **Request:**
    /// ```json
    /// {
    ///   "type": "request",
    ///   "command": "ct/py-processes",
    ///   "seq": 1,
    ///   "arguments": {
    ///     "tracePath": "/path/to/trace"
    ///   }
    /// }
    /// ```
    ///
    /// **Response:**
    /// ```json
    /// {
    ///   "type": "response",
    ///   "request_seq": 1,
    ///   "success": true,
    ///   "command": "ct/py-processes",
    ///   "body": {
    ///     "processes": [
    ///       {"id": 1, "name": "main", "command": "/usr/bin/prog"},
    ///       {"id": 2, "name": "child", "command": "/usr/bin/prog --worker"}
    ///     ]
    ///   }
    /// }
    /// ```
    async fn handle_py_processes(
        &mut self,
        seq: i64,
        args: Option<&Value>,
    ) -> Result<(), Box<dyn Error>> {
        let trace_path_str = match args
            .and_then(|a| a.get("tracePath"))
            .and_then(Value::as_str)
        {
            Some(p) => p.to_string(),
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-processes",
                    "missing 'tracePath' in arguments",
                );
                return Ok(());
            }
        };

        let session = SessionKey::for_request(&trace_path_str, args);

        let backend_id = match self.backend_id_for_trace(&session) {
            Some(id) => id,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-processes",
                    &self.no_session_error_message(&trace_path_str),
                );
                return Ok(());
            }
        };

        // Reset TTL for this trace (inspection counts as activity).
        self.reset_ttl_for_backend_id(backend_id);

        // Get a unique seq for the DAP command sent to the backend.
        let dap_seq = match self.daemon_state.as_mut() {
            Some(ds) => ds.py_bridge.next_seq(),
            None => return Ok(()),
        };

        // Build and send the ct/list-processes command to the backend.
        let dap_request = serde_json::json!({
            "type": "request",
            "command": "ct/list-processes",
            "seq": dap_seq,
            "arguments": {},
        });

        if let Err(e) = self.message(backend_id, dap_request).await {
            self.send_py_command_error(
                seq,
                "ct/py-processes",
                &format!("failed to send command to backend: {e}"),
            );
            return Ok(());
        }

        // Register the pending request.
        let client_id = self.lookup_client_for_seq(seq).unwrap_or(0);
        if let Some(ds) = self.daemon_state.as_mut() {
            ds.py_bridge.pending_requests.push(PendingPyRequest {
                kind: PendingPyRequestKind::Processes,
                client_id,
                original_seq: seq,
                backend_seq: dap_seq,
                response_command: "ct/py-processes".to_string(),
                expression: String::new(),
            });
        }

        Ok(())
    }

    /// Handles `ct/py-select-process` requests from Python clients.
    ///
    /// Translates the request into a `ct/select-replay` DAP command, sends
    /// it to the backend, and registers a pending request that will be
    /// completed when the backend responds.
    ///
    /// # Wire protocol
    ///
    /// **Request:**
    /// ```json
    /// {
    ///   "type": "request",
    ///   "command": "ct/py-select-process",
    ///   "seq": 1,
    ///   "arguments": {
    ///     "tracePath": "/path/to/trace",
    ///     "processId": 2
    ///   }
    /// }
    /// ```
    ///
    /// **Response:**
    /// ```json
    /// {
    ///   "type": "response",
    ///   "request_seq": 1,
    ///   "success": true,
    ///   "command": "ct/py-select-process",
    ///   "body": {}
    /// }
    /// ```
    async fn handle_py_select_process(
        &mut self,
        seq: i64,
        args: Option<&Value>,
    ) -> Result<(), Box<dyn Error>> {
        let trace_path_str = match args
            .and_then(|a| a.get("tracePath"))
            .and_then(Value::as_str)
        {
            Some(p) => p.to_string(),
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-select-process",
                    "missing 'tracePath' in arguments",
                );
                return Ok(());
            }
        };

        let process_id = match args
            .and_then(|a| a.get("processId"))
            .and_then(Value::as_i64)
        {
            Some(id) => id,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-select-process",
                    "missing 'processId' in arguments",
                );
                return Ok(());
            }
        };

        let session = SessionKey::for_request(&trace_path_str, args);

        let backend_id = match self.backend_id_for_trace(&session) {
            Some(id) => id,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-select-process",
                    &self.no_session_error_message(&trace_path_str),
                );
                return Ok(());
            }
        };

        // Reset TTL for this trace (inspection counts as activity).
        self.reset_ttl_for_backend_id(backend_id);

        // Get a unique seq for the DAP command sent to the backend.
        let dap_seq = match self.daemon_state.as_mut() {
            Some(ds) => ds.py_bridge.next_seq(),
            None => return Ok(()),
        };

        // Build and send the ct/select-replay command to the backend.
        let dap_request = serde_json::json!({
            "type": "request",
            "command": "ct/select-replay",
            "seq": dap_seq,
            "arguments": {
                "processId": process_id,
            },
        });

        if let Err(e) = self.message(backend_id, dap_request).await {
            self.send_py_command_error(
                seq,
                "ct/py-select-process",
                &format!("failed to send command to backend: {e}"),
            );
            return Ok(());
        }

        // Register the pending request.
        let client_id = self.lookup_client_for_seq(seq).unwrap_or(0);
        if let Some(ds) = self.daemon_state.as_mut() {
            ds.py_bridge.pending_requests.push(PendingPyRequest {
                kind: PendingPyRequestKind::SelectProcess,
                client_id,
                original_seq: seq,
                backend_seq: dap_seq,
                response_command: "ct/py-select-process".to_string(),
                expression: String::new(),
            });
        }

        Ok(())
    }

    // -----------------------------------------------------------------------
    // ct/py-memory-diff handler (MW47 Phase 2 — MCR agentic interface)
    // -----------------------------------------------------------------------

    /// Handles `ct/py-memory-diff` (alias: `ct/mcrMemoryDiff`) requests.
    ///
    /// MW47 Phase 2.  MCR's MW47 Phase 1b producer emits
    /// `evMemorySnapshot` events into per-thread rings whenever
    /// `CT_MEMORY_SNAPSHOT_AT_EVENT=1` is set at recording time.  This
    /// handler decodes those snapshots from the `.ct` trace file and
    /// returns the page-by-page diff between two snapshot GEIDs, plus
    /// the GEID of the earliest divergent snapshot in `(eventA, eventB]`
    /// — the field a cascade-peeling agent binary-searches on to
    /// localise the missing-capture surface.
    ///
    /// The decode itself is delegated to the `ct_memdiff_helper` binary
    /// (built from `ct_replayer/src/ct_memdiff_helper.nim`) which is
    /// spawned as a one-shot subprocess.  This keeps the
    /// backend-manager free of any CTFS / per-thread-ring decoder
    /// dependency.  The helper is NOT a user-facing `ct-mcr`
    /// subcommand — see `feedback_codetracer_agentic_interface`.
    ///
    /// Helper-binary discovery: `CODETRACER_CT_MEMDIFF_HELPER` env var
    /// (absolute path) takes precedence; otherwise we look for
    /// `ct_memdiff_helper`/`ct_memdiff_helper.exe` next to the current
    /// backend-manager executable, then fall back to `$PATH`.
    ///
    /// **Wire protocol**
    ///
    /// Request:
    /// ```json
    /// {
    ///   "type": "request",
    ///   "command": "ct/py-memory-diff",
    ///   "seq": 7,
    ///   "arguments": {
    ///     "tracePath": "/path/to/trace.ct",
    ///     "eventA": 42,
    ///     "eventB": 4096,
    ///     "maxDiffs": 16
    ///   }
    /// }
    /// ```
    ///
    /// Response body:
    /// ```json
    /// {
    ///   "eventA": 42, "eventB": 4096,
    ///   "snapshotsInRange": 1024,
    ///   "pagesCompared": 4711,
    ///   "differingPages": 3, "truncated": false,
    ///   "firstDivergenceEventGeid": 117,
    ///   "diffs": [
    ///     {"pageIndex": 12, "pageVa": "0x...", "regionBase": "0x...",
    ///      "regionProtect": 4, "hashRecorded": "0x...", "hashReplayed": "0x..."}
    ///   ]
    /// }
    /// ```
    async fn handle_py_memory_diff(
        &mut self,
        seq: i64,
        args: Option<&Value>,
    ) -> Result<(), Box<dyn Error>> {
        const COMMAND: &str = "ct/py-memory-diff";

        let trace_path_str = match args
            .and_then(|a| a.get("tracePath"))
            .and_then(Value::as_str)
        {
            Some(p) => p.to_string(),
            None => {
                self.send_py_command_error(seq, COMMAND, "missing 'tracePath' in arguments");
                return Ok(());
            }
        };

        let event_a = match args.and_then(|a| a.get("eventA")).and_then(Value::as_i64) {
            Some(v) => v,
            None => {
                self.send_py_command_error(seq, COMMAND, "missing 'eventA' in arguments");
                return Ok(());
            }
        };

        let event_b = match args.and_then(|a| a.get("eventB")).and_then(Value::as_i64) {
            Some(v) => v,
            None => {
                self.send_py_command_error(seq, COMMAND, "missing 'eventB' in arguments");
                return Ok(());
            }
        };

        let max_diffs = args
            .and_then(|a| a.get("maxDiffs"))
            .and_then(Value::as_i64)
            .unwrap_or(16)
            .max(1);

        // Reset TTL for the session (if any) backing this trace; the
        // memory-diff query doesn't actually drive the backend, but if
        // a session is loaded we don't want it to expire mid-bisect.
        let session = SessionKey::for_request(&trace_path_str, args);
        if let Some(backend_id) = self.backend_id_for_trace(&session) {
            self.reset_ttl_for_backend_id(backend_id);
        }

        // Resolve the helper binary path.
        let helper = match Self::resolve_memdiff_helper() {
            Some(p) => p,
            None => {
                self.send_py_command_error(
                    seq,
                    COMMAND,
                    "ct_memdiff_helper not found (set CODETRACER_CT_MEMDIFF_HELPER or \
                     ensure the binary is next to backend-manager or on PATH)",
                );
                return Ok(());
            }
        };

        // Build the JSON request for the helper.
        let helper_request = serde_json::json!({
            "tracePath": trace_path_str,
            "eventA": event_a,
            "eventB": event_b,
            "maxDiffs": max_diffs,
        });
        let helper_request_str = helper_request.to_string();

        // Spawn the helper and collect stdout.  This is a fast,
        // one-shot operation; we spawn synchronously via tokio's
        // blocking subprocess primitive to avoid further wiring.
        let client_id = self.lookup_client_for_seq(seq);
        let send_response = move |daemon_send: Box<dyn FnOnce(Value) + Send>, resp: Value| {
            daemon_send(resp);
        };
        // We need a closure to ship the response either through the
        // daemon's client channel or the legacy manager sender.  Build
        // both responses (success / failure) here and dispatch.
        let stdout_bytes = match tokio::process::Command::new(&helper)
            .arg("--stdin")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
        {
            Ok(mut child) => {
                if let Some(stdin) = child.stdin.as_mut() {
                    use tokio::io::AsyncWriteExt as _;
                    if let Err(e) = stdin.write_all(helper_request_str.as_bytes()).await {
                        self.send_py_command_error(
                            seq,
                            COMMAND,
                            &format!("failed writing helper stdin: {e}"),
                        );
                        return Ok(());
                    }
                }
                match child.wait_with_output().await {
                    Ok(output) => output.stdout,
                    Err(e) => {
                        self.send_py_command_error(
                            seq,
                            COMMAND,
                            &format!("ct_memdiff_helper wait failed: {e}"),
                        );
                        return Ok(());
                    }
                }
            }
            Err(e) => {
                self.send_py_command_error(
                    seq,
                    COMMAND,
                    &format!(
                        "failed spawning ct_memdiff_helper at {}: {e}",
                        helper.display()
                    ),
                );
                return Ok(());
            }
        };

        // The helper prints exactly one JSON object followed by a newline.
        let stdout_str = String::from_utf8_lossy(&stdout_bytes);
        let parsed: Value = match serde_json::from_str(stdout_str.trim()) {
            Ok(v) => v,
            Err(e) => {
                self.send_py_command_error(
                    seq,
                    COMMAND,
                    &format!(
                        "ct_memdiff_helper produced invalid JSON ({e}); raw output: {}",
                        stdout_str.trim()
                    ),
                );
                return Ok(());
            }
        };

        let success = parsed
            .get("success")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let response = if success {
            let body = parsed
                .get("body")
                .cloned()
                .unwrap_or_else(|| serde_json::json!({}));
            json!({
                "type": "response",
                "request_seq": seq,
                "success": true,
                "command": COMMAND,
                "body": body,
            })
        } else {
            let msg = parsed
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("ct_memdiff_helper reported failure")
                .to_string();
            json!({
                "type": "response",
                "request_seq": seq,
                "success": false,
                "command": COMMAND,
                "message": msg,
            })
        };

        if self.daemon_state.is_some() {
            if let Some(cid) = client_id {
                self.send_to_client(cid, response);
            }
        } else {
            self.send_manager_message(response);
        }
        let _ = send_response; // silence the unused-closure warning when refactored
        Ok(())
    }

    // -----------------------------------------------------------------------
    // ct/py-memory-diff-record-vs-replay handler (MW47 Phase 3)
    // -----------------------------------------------------------------------

    /// Handles `ct/py-memory-diff-record-vs-replay` (alias:
    /// `ct/mcrMemoryDiffRecordVsReplay`).
    ///
    /// MW47 Phase 3.  Cross-trace diff between the recorded snapshot
    /// at GEID N (gated by `CT_MEMORY_SNAPSHOT_AT_GEID=N` during
    /// recording) and the replayer's standalone single-shot file
    /// (gated by `CT_REPLAY_SNAPSHOT_AT_GEID=N` during the verify
    /// replay).  The agent binary-searches over GEID N to localise
    /// the first point at which replay diverges from record.
    ///
    /// **Wire protocol**
    ///
    /// Request:
    /// ```json
    /// {
    ///   "type": "request",
    ///   "command": "ct/py-memory-diff-record-vs-replay",
    ///   "seq": 9,
    ///   "arguments": {
    ///     "recordTrace":    "/path/to/recorded.ct",
    ///     "replaySnapshot": "/path/to/<trace>.replay-snapshot-geid-<N>.bin",
    ///     "geid":           4096,
    ///     "maxDiffs":       16
    ///   }
    /// }
    /// ```
    ///
    /// Response body shape is identical to `ct/py-memory-diff` —
    /// returns a `MemoryDiffResult` JSON with `differingPages`,
    /// `firstDivergenceEventGeid`, and a `diffs` array.
    async fn handle_py_memory_diff_record_vs_replay(
        &mut self,
        seq: i64,
        args: Option<&Value>,
    ) -> Result<(), Box<dyn Error>> {
        const COMMAND: &str = "ct/py-memory-diff-record-vs-replay";

        let record_trace = match args
            .and_then(|a| a.get("recordTrace"))
            .and_then(Value::as_str)
        {
            Some(p) => p.to_string(),
            None => {
                self.send_py_command_error(seq, COMMAND, "missing 'recordTrace' in arguments");
                return Ok(());
            }
        };

        let replay_snapshot = match args
            .and_then(|a| a.get("replaySnapshot"))
            .and_then(Value::as_str)
        {
            Some(p) => p.to_string(),
            None => {
                self.send_py_command_error(seq, COMMAND, "missing 'replaySnapshot' in arguments");
                return Ok(());
            }
        };

        let geid = match args.and_then(|a| a.get("geid")).and_then(Value::as_i64) {
            Some(v) => v,
            None => {
                self.send_py_command_error(seq, COMMAND, "missing 'geid' in arguments");
                return Ok(());
            }
        };

        let max_diffs = args
            .and_then(|a| a.get("maxDiffs"))
            .and_then(Value::as_i64)
            .unwrap_or(16)
            .max(1);

        // Refresh the session TTL if one is loaded for this trace —
        // bisect agents call back-to-back and shouldn't lose state.
        let session = SessionKey::for_request(&record_trace, args);
        if let Some(backend_id) = self.backend_id_for_trace(&session) {
            self.reset_ttl_for_backend_id(backend_id);
        }

        let helper = match Self::resolve_memdiff_helper() {
            Some(p) => p,
            None => {
                self.send_py_command_error(
                    seq,
                    COMMAND,
                    "ct_memdiff_helper not found (set CODETRACER_CT_MEMDIFF_HELPER or \
                     ensure the binary is next to backend-manager or on PATH)",
                );
                return Ok(());
            }
        };

        let helper_request = serde_json::json!({
            "command": "record-vs-replay",
            "recordTrace": record_trace,
            "replaySnapshot": replay_snapshot,
            "geid": geid,
            "maxDiffs": max_diffs,
        });
        let helper_request_str = helper_request.to_string();

        let client_id = self.lookup_client_for_seq(seq);
        let stdout_bytes = match tokio::process::Command::new(&helper)
            .arg("--stdin")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
        {
            Ok(mut child) => {
                if let Some(stdin) = child.stdin.as_mut() {
                    use tokio::io::AsyncWriteExt as _;
                    if let Err(e) = stdin.write_all(helper_request_str.as_bytes()).await {
                        self.send_py_command_error(
                            seq,
                            COMMAND,
                            &format!("failed writing helper stdin: {e}"),
                        );
                        return Ok(());
                    }
                }
                match child.wait_with_output().await {
                    Ok(output) => output.stdout,
                    Err(e) => {
                        self.send_py_command_error(
                            seq,
                            COMMAND,
                            &format!("ct_memdiff_helper wait failed: {e}"),
                        );
                        return Ok(());
                    }
                }
            }
            Err(e) => {
                self.send_py_command_error(
                    seq,
                    COMMAND,
                    &format!(
                        "failed spawning ct_memdiff_helper at {}: {e}",
                        helper.display()
                    ),
                );
                return Ok(());
            }
        };

        let stdout_str = String::from_utf8_lossy(&stdout_bytes);
        let parsed: Value = match serde_json::from_str(stdout_str.trim()) {
            Ok(v) => v,
            Err(e) => {
                self.send_py_command_error(
                    seq,
                    COMMAND,
                    &format!(
                        "ct_memdiff_helper produced invalid JSON ({e}); raw output: {}",
                        stdout_str.trim()
                    ),
                );
                return Ok(());
            }
        };

        let success = parsed
            .get("success")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let response = if success {
            let body = parsed
                .get("body")
                .cloned()
                .unwrap_or_else(|| serde_json::json!({}));
            json!({
                "type": "response",
                "request_seq": seq,
                "success": true,
                "command": COMMAND,
                "body": body,
            })
        } else {
            let msg = parsed
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("ct_memdiff_helper reported failure")
                .to_string();
            json!({
                "type": "response",
                "request_seq": seq,
                "success": false,
                "command": COMMAND,
                "message": msg,
            })
        };

        if self.daemon_state.is_some() {
            if let Some(cid) = client_id {
                self.send_to_client(cid, response);
            }
        } else {
            self.send_manager_message(response);
        }
        Ok(())
    }

    /// Resolves the path to the `ct_memdiff_helper` executable used by
    /// `handle_py_memory_diff`.  Search order:
    ///
    /// 1. `CODETRACER_CT_MEMDIFF_HELPER` env var (absolute path).
    /// 2. Same directory as the current executable.
    /// 3. `$PATH` lookup.
    ///
    /// Returns `None` if no candidate exists / is executable.
    fn resolve_memdiff_helper() -> Option<PathBuf> {
        if let Ok(env_path) = std::env::var("CODETRACER_CT_MEMDIFF_HELPER") {
            let candidate = PathBuf::from(env_path);
            if candidate.is_file() {
                return Some(candidate);
            }
        }
        let exe_name = if cfg!(windows) {
            "ct_memdiff_helper.exe"
        } else {
            "ct_memdiff_helper"
        };
        if let Ok(self_exe) = std::env::current_exe()
            && let Some(dir) = self_exe.parent()
        {
            let sibling = dir.join(exe_name);
            if sibling.is_file() {
                return Some(sibling);
            }
        }
        // PATH lookup.
        if let Ok(path_env) = std::env::var("PATH") {
            for entry in std::env::split_paths(&path_env) {
                let candidate = entry.join(exe_name);
                if candidate.is_file() {
                    return Some(candidate);
                }
            }
        }
        None
    }

    // -----------------------------------------------------------------------
    // ct/open-trace, ct/trace-info, ct/close-trace handlers
    // -----------------------------------------------------------------------

    /// Sends a response to the client that sent the request with `seq`, or
    /// falls back to the manager sender (for legacy mode).
    fn send_response_for_seq(&self, seq: i64, response: Value) {
        let client_id = self.lookup_client_for_seq(seq);
        if self.daemon_state.is_some() {
            if let Some(cid) = client_id {
                self.send_to_client(cid, response);
            }
        } else {
            self.send_manager_message(response);
        }
    }

    /// Handles `ct/open-trace` requests.
    ///
    /// Opens a trace session: reads metadata, spawns the backend, runs DAP
    /// init, and registers the session.  If the trace is already loaded,
    /// resets the TTL and returns the existing session info.
    async fn handle_open_trace(
        &mut self,
        seq: i64,
        args: Option<&Value>,
    ) -> Result<(), Box<dyn Error>> {
        // Extract the trace path from arguments.
        let trace_path_str = match args
            .and_then(|a| a.get("tracePath"))
            .and_then(Value::as_str)
        {
            Some(p) => p.to_string(),
            None => {
                let response = json!({
                    "type": "response",
                    "request_seq": seq,
                    "success": false,
                    "command": "ct/open-trace",
                    "message": "missing 'tracePath' in arguments"
                });
                self.send_response_for_seq(seq, response);
                return Ok(());
            }
        };

        let trace_path = PathBuf::from(&trace_path_str);
        // The session is the trace AND the host-read setting the request
        // carries: a backend started for one setting is never reused for a
        // request with the other (see `crate::session::SessionKey`).
        let session = SessionKey::for_request(&trace_path_str, args);

        // Check if already loaded — return existing session and reset TTL.
        //
        // When reusing a cached session we must clear stale breakpoint/
        // watchpoint state from any previous script execution, and reset
        // the backend replay position to the beginning.  Without this,
        // breakpoints accumulate across `ct/exec-script` invocations and
        // the `setBreakpoints` DAP command sends ALL accumulated
        // breakpoints, causing `continue` to hit unexpected locations.
        if let Some(ds) = self.daemon_state.as_mut()
            && ds.session_manager.has_session(&session)
        {
            ds.session_manager.reset_ttl(&session);

            // Clear accumulated breakpoint/watchpoint state from previous
            // script runs so the new script starts with a clean slate.
            ds.py_bridge.breakpoint_state_mut(&session).clear_all();
            #[cfg(test)]
            if args
                .and_then(|a| a.get("testPanicStage"))
                .and_then(Value::as_str)
                == Some("cached")
            {
                panic!("test failure after creating cached-session bridge state");
            }

            if let Some(info) = ds.session_manager.get_session(&session) {
                let backend_id = info.backend_id;

                // Send an empty setBreakpoints to the backend so its
                // replay.breakpoint_list is also cleared.  We use an
                // empty source path; the handler calls clear_breakpoints()
                // unconditionally.
                let clear_bp_seq = ds.py_bridge.next_seq();
                let clear_bp_request = json!({
                    "type": "request",
                    "command": "setBreakpoints",
                    "seq": clear_bp_seq,
                    "arguments": {
                        "source": {"path": ""},
                        "breakpoints": [],
                    }
                });
                // Also reset the replay position to the start so each
                // script begins at the same position.
                let reset_seq = ds.py_bridge.next_seq();
                let reset_request = json!({
                    "type": "request",
                    "command": "ct/run-to-entry",
                    "seq": reset_seq,
                    "arguments": {}
                });
                // Fire-and-forget: consume the responses silently.
                ds.py_bridge.pending_requests.push(PendingPyRequest {
                    kind: PendingPyRequestKind::Unobserved(
                        python_bridge::UnobservedReason::OpenTraceCachedSessionReset,
                    ),
                    client_id: 0,
                    original_seq: 0,
                    backend_seq: clear_bp_seq,
                    response_command: String::new(),
                    expression: String::new(),
                });
                ds.py_bridge.pending_requests.push(PendingPyRequest {
                    kind: PendingPyRequestKind::Unobserved(
                        python_bridge::UnobservedReason::OpenTraceCachedSessionReset,
                    ),
                    client_id: 0,
                    original_seq: 0,
                    backend_seq: reset_seq,
                    response_command: String::new(),
                    expression: String::new(),
                });

                let _ = self.message(backend_id, clear_bp_request).await;
                let _ = self.message(backend_id, reset_request).await;

                let response = json!({
                    "type": "response",
                    "request_seq": seq,
                    "success": true,
                    "command": "ct/open-trace",
                    "body": {
                        "tracePath": trace_path_str,
                        "backendId": info.backend_id,
                        "language": info.language,
                        "totalEvents": info.total_events,
                        "sourceFiles": info.source_files,
                        "program": info.program,
                        "workdir": info.workdir,
                        "hostSourceReads": session.host_source_reads.is_allowed(),
                        "cached": true,
                    }
                });
                self.send_response_for_seq(seq, response);
                return Ok(());
            }
        }

        // Check max sessions limit.
        if let Some(ds) = self.daemon_state.as_ref()
            && ds.session_manager.session_count() >= ds.config.max_sessions
        {
            let response = json!({
                "type": "response",
                "request_seq": seq,
                "success": false,
                "command": "ct/open-trace",
                "message": format!(
                    "maximum number of sessions ({}) reached",
                    ds.config.max_sessions
                )
            });
            self.send_response_for_seq(seq, response);
            return Ok(());
        }

        // Read metadata from trace files.
        let metadata = match trace_metadata::read_trace_metadata(&trace_path) {
            Ok(m) => m,
            Err(e) => {
                let response = json!({
                    "type": "response",
                    "request_seq": seq,
                    "success": false,
                    "command": "ct/open-trace",
                    "message": format!("cannot read trace metadata: {e}")
                });
                self.send_response_for_seq(seq, response);
                return Ok(());
            }
        };

        // Determine which replay-server command to spawn.
        // Tests can override via CODETRACER_REPLAY_SERVER_CMD (preferred) or
        // the legacy CODETRACER_DB_BACKEND_CMD env var.
        let backend_cmd = std::env::var("CODETRACER_REPLAY_SERVER_CMD")
            .or_else(|_| std::env::var("CODETRACER_DB_BACKEND_CMD"))
            .unwrap_or_else(|_| "replay-server".to_string());

        // Unit dispatch tests use the real sibling backend without changing
        // the process-wide environment shared by other tests.
        #[cfg(test)]
        let backend_cmd = args
            .and_then(|a| a.get("testReplayServerCommand"))
            .and_then(Value::as_str)
            .map(str::to_owned)
            .unwrap_or(backend_cmd);

        // The subcommand: `dap-server`, or the mock's when the explicit test
        // flag asks for it.  Never inferred from `backend_cmd`: that path is
        // wherever the user, the workspace or the CI runner put the build,
        // so a word in it says nothing about which program it is.
        let subcommand = match replay_backend_subcommand(
            std::env::var_os(REPLAY_SERVER_MOCK_DAP_ENV).as_deref(),
        ) {
            Ok(subcommand) => subcommand,
            Err(e) => {
                let response = json!({
                    "type": "response",
                    "request_seq": seq,
                    "success": false,
                    "command": "ct/open-trace",
                    "message": format!("cannot choose the replay backend: {e}")
                });
                self.send_response_for_seq(seq, response);
                return Ok(());
            }
        };
        let backend_args = [subcommand];

        // Spawn the backend process (raw, without installing channels).
        let (backend_id, sender, mut receiver) =
            match self.start_replay_raw(&backend_cmd, &backend_args).await {
                Ok(result) => result,
                Err(e) => {
                    let response = json!({
                        "type": "response",
                        "request_seq": seq,
                        "success": false,
                        "command": "ct/open-trace",
                        "message": format!("failed to spawn backend: {e}")
                    });
                    self.send_response_for_seq(seq, response);
                    return Ok(());
                }
            };

        #[cfg(test)]
        self.inject_open_trace_failure(args, "after-start", &session, backend_id)?;

        // Build DAP launch options.  If the trace directory contains an `rr/`
        // subdirectory (Linux RR traces) or `.run` files (Windows TTD traces),
        // we need to tell replay-server where ct-native-replay is so it can spawn
        // the replay worker.
        //
        // The ct-native-replay path is resolved from (in priority order):
        //   1. `CODETRACER_CT_NATIVE_REPLAY_CMD` environment variable
        //   2. `ct-native-replay` beside the current executable, then on PATH
        //
        // Reference: replay-server/src/dap.rs — `LaunchRequestArguments.ctRRWorkerExe`
        let dap_launch_opts = {
            let mut opts = dap_init::DapLaunchOptions {
                host_source_reads: Some(session.host_source_reads),
                ..dap_init::DapLaunchOptions::default()
            };
            let needs_rr_support = trace_path.join("rr").is_dir()
                || trace_path.join("ttd-trace-manifest.json").is_file()
                || trace_path.extension().is_some_and(|ext| ext == "ct")
                || has_ctfs_magic(&trace_path);
            if needs_rr_support {
                let rr_support_cmd = std::env::var("CODETRACER_CT_NATIVE_REPLAY_CMD")
                    .ok()
                    .map(PathBuf::from)
                    .or_else(|| {
                        // Try sibling of the current executable first (same bin/ dir).
                        let exe_suffix = std::env::consts::EXE_SUFFIX;
                        let exe_names = [format!("ct-native-replay{}", exe_suffix)];
                        for exe_name in &exe_names {
                            if let Ok(self_exe) = std::env::current_exe()
                                && let Some(sibling) = self_exe
                                    .parent()
                                    .map(|dir| dir.join(exe_name))
                                    .filter(|p| p.is_file())
                            {
                                return Some(sibling);
                            }
                        }
                        // Fall back to PATH search.
                        let which_cmd = if cfg!(windows) { "where" } else { "which" };
                        for exe_name in &exe_names {
                            if let Some(path) = std::process::Command::new(which_cmd)
                                .arg(exe_name)
                                .output()
                                .ok()
                                .filter(|o| o.status.success())
                                .and_then(|o| {
                                    let s = String::from_utf8_lossy(&o.stdout)
                                        .lines()
                                        .next()
                                        .unwrap_or("")
                                        .trim()
                                        .to_string();
                                    if s.is_empty() {
                                        None
                                    } else {
                                        Some(PathBuf::from(s))
                                    }
                                })
                            {
                                return Some(path);
                            }
                        }
                        None
                    });

                if let Some(ref exe) = rr_support_cmd {
                    info!(
                        "RR trace detected, using ct-native-replay: {}",
                        exe.display()
                    );
                    opts.ct_rr_worker_exe = rr_support_cmd;
                } else {
                    warn!(
                        "RR trace detected at {} but ct-native-replay not found; \
                         DAP init may fail",
                        trace_path.display()
                    );
                }
            }
            opts
        };

        // Run DAP init sequence.
        // Large DB traces (e.g. 96 MB Python traces) can take significant
        // time to parse and post-process.  Use a generous per-step timeout
        // so that `setup()` in replay-server has time to complete.
        let dap_timeout = Duration::from_secs(120);
        match dap_init::run_dap_init(
            &sender,
            &mut receiver,
            &trace_path,
            dap_timeout,
            &dap_launch_opts,
        )
        .await
        {
            Ok(_init_result) => {
                info!(
                    "DAP init completed for trace {} (backend_id={backend_id})",
                    trace_path.display()
                );
            }
            Err(e) => {
                warn!("DAP init failed for trace {}: {e}", trace_path.display());
                // Try to stop the failed backend.
                let _ = self.stop_replay(backend_id).await;
                let response = json!({
                    "type": "response",
                    "request_seq": seq,
                    "success": false,
                    "command": "ct/open-trace",
                    "message": format!("DAP initialization failed: {e}")
                });
                self.send_response_for_seq(seq, response);
                return Ok(());
            }
        }

        // After DAP init, query the initial location via stackTrace.
        // This provides the Python client with the starting position
        // without requiring a separate navigation call.
        let initial_location = {
            let st_request = json!({
                "type": "request",
                "command": "stackTrace",
                "seq": 999_999,
                "arguments": {"threadId": 1}
            });
            let _ = sender.send(st_request);

            // Wait for the stackTrace response with a short timeout.
            let mut location =
                json!({"path": "", "line": 0, "column": 0, "ticks": 0, "endOfTrace": false});
            let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
            loop {
                let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
                if remaining.is_zero() {
                    warn!("Timeout waiting for initial stackTrace");
                    break;
                }

                tokio::select! {
                    msg = receiver.recv() => {
                        if let Some(msg) = msg {
                            if msg.get("type").and_then(Value::as_str) == Some("response")
                                && msg.get("command").and_then(Value::as_str) == Some("stackTrace")
                            {
                                location = python_bridge::extract_location_from_stack_trace(&msg);
                                break;
                            }
                            // Not the stackTrace response; discard and keep waiting.
                        } else {
                            warn!("Channel closed while waiting for initial stackTrace");
                            break;
                        }
                    }
                    _ = tokio::time::sleep(remaining) => {
                        warn!("Timeout waiting for initial stackTrace");
                        break;
                    }
                }
            }
            location
        };

        // Install channels for normal routing.
        self.install_replay_channels(backend_id, sender, receiver);

        // Register session with metadata.
        if let Some(ds) = self.daemon_state.as_mut()
            && let Err(e) =
                ds.session_manager
                    .add_session_with_metadata(session.clone(), backend_id, &metadata)
        {
            warn!("Failed to register session for {session}: {e}");
        }

        #[cfg(test)]
        self.inject_open_trace_failure(args, "after-register", &session, backend_id)?;

        let response = json!({
            "type": "response",
            "request_seq": seq,
            "success": true,
            "command": "ct/open-trace",
            "body": {
                "tracePath": trace_path_str,
                "backendId": backend_id,
                // M-REC-1 / Recording-Identifier-Migration §6.6: the canonical
                // recording identifier (UUIDv7) is surfaced through the DAP
                // open-trace response so frontends, sharing UIs and
                // observability integrations all see the same id without
                // needing to re-parse `meta.dat`.
                "recordingId": metadata.recording_id,
                "language": metadata.language,
                "totalEvents": metadata.total_events,
                "sourceFiles": metadata.source_files,
                "program": metadata.program,
                "workdir": metadata.workdir,
                "hostSourceReads": session.host_source_reads.is_allowed(),
                "cached": false,
                "initialLocation": initial_location,
            }
        });
        self.send_response_for_seq(seq, response);
        Ok(())
    }

    /// Fault injection belongs to the real handler, so its unwind crosses
    /// exactly the ownership and registration steps used in production.
    #[cfg(test)]
    fn inject_open_trace_failure(
        &mut self,
        args: Option<&Value>,
        stage: &str,
        session: &SessionKey,
        backend_id: usize,
    ) -> Result<(), Box<dyn Error>> {
        if args
            .and_then(|a| a.get("testPanicStage"))
            .and_then(Value::as_str)
            != Some(stage)
        {
            return Ok(());
        }
        if stage == "after-register" {
            // Make bridge cleanup observable: the same lazy state allocation
            // as a breakpoint handler, before this request unwinds.
            self.daemon_state
                .as_mut()
                .unwrap()
                .py_bridge
                .breakpoint_state_mut(session);
        }
        let pid = self.children[backend_id].as_ref().unwrap().id().unwrap();
        let message = format!("test failure {stage} pid={pid}");
        if args
            .and_then(|a| a.get("testFailureKind"))
            .and_then(Value::as_str)
            == Some("error")
        {
            return Err(message.into());
        }
        panic!("{message}");
    }

    /// Handles `ct/trace-info` requests.
    ///
    /// Returns metadata for a loaded trace session.
    fn handle_trace_info(&self, seq: i64, args: Option<&Value>) -> Result<(), Box<dyn Error>> {
        let trace_path_str = match args
            .and_then(|a| a.get("tracePath"))
            .and_then(Value::as_str)
        {
            Some(p) => p.to_string(),
            None => {
                let response = json!({
                    "type": "response",
                    "request_seq": seq,
                    "success": false,
                    "command": "ct/trace-info",
                    "message": "missing 'tracePath' in arguments"
                });
                self.send_response_for_seq(seq, response);
                return Ok(());
            }
        };

        let session = SessionKey::for_request(&trace_path_str, args);

        let session_info = self
            .daemon_state
            .as_ref()
            .and_then(|ds| ds.session_manager.get_session(&session));

        match session_info {
            Some(info) => {
                let response = json!({
                    "type": "response",
                    "request_seq": seq,
                    "success": true,
                    "command": "ct/trace-info",
                    "body": {
                        "tracePath": trace_path_str,
                        "language": info.language,
                        "totalEvents": info.total_events,
                        "sourceFiles": info.source_files,
                        "program": info.program,
                        "workdir": info.workdir,
                        "hostSourceReads": session.host_source_reads.is_allowed(),
                    }
                });
                self.send_response_for_seq(seq, response);
            }
            None => {
                let response = json!({
                    "type": "response",
                    "request_seq": seq,
                    "success": false,
                    "command": "ct/trace-info",
                    "message": self.no_session_error_message(&trace_path_str)
                });
                self.send_response_for_seq(seq, response);
            }
        }
        Ok(())
    }

    /// Handles `ct/exec-script` requests.
    ///
    /// Spawns a Python subprocess that connects back to the daemon, opens
    /// the specified trace, and executes the provided script.  The daemon
    /// captures stdout/stderr and returns the result to the requesting client.
    ///
    /// **Important**: The Python subprocess connects back to the daemon via
    /// the Unix socket and sends `ct/open-trace`.  If we held the
    /// `BackendManager` mutex while waiting for the subprocess, the dispatch
    /// loop would deadlock trying to acquire the same mutex for the incoming
    /// `ct/open-trace` request.  To avoid this we extract all necessary data
    /// synchronously (while we still hold the lock), clone the response
    /// sender, and spawn a **detached** tokio task that runs the subprocess
    /// and sends the response independently.  The method returns immediately,
    /// releasing the mutex so the dispatch loop can continue processing
    /// messages from the Python subprocess.
    ///
    /// Expected arguments:
    /// - `tracePath` (string, required): path to the trace directory.
    /// - `script` (string, required): Python code to execute.
    /// - `timeout` (integer, optional): execution timeout in seconds
    ///   (defaults to [`script_executor::DEFAULT_TIMEOUT_SECS`]).
    ///
    /// The response body contains `stdout`, `stderr`, `exitCode`, and
    /// `timedOut` fields.
    fn handle_exec_script(&mut self, seq: i64, args: Option<&Value>) -> Result<(), Box<dyn Error>> {
        // --- Extract trace path ---
        let trace_path_str = match args
            .and_then(|a| a.get("tracePath"))
            .and_then(Value::as_str)
        {
            Some(p) => p.to_string(),
            None => {
                let response = json!({
                    "type": "response",
                    "request_seq": seq,
                    "success": false,
                    "command": "ct/exec-script",
                    "message": "missing 'tracePath' in arguments"
                });
                self.send_response_for_seq(seq, response);
                return Ok(());
            }
        };

        // --- Extract script ---
        let script = match args.and_then(|a| a.get("script")).and_then(Value::as_str) {
            Some(s) => s.to_string(),
            None => {
                let response = json!({
                    "type": "response",
                    "request_seq": seq,
                    "success": false,
                    "command": "ct/exec-script",
                    "message": "missing 'script' in arguments"
                });
                self.send_response_for_seq(seq, response);
                return Ok(());
            }
        };

        // --- Extract optional timeout: 1 s to the ceiling, else refused ---
        let timeout_secs = match args.and_then(|a| a.get("timeout")) {
            None | Some(Value::Null) => script_executor::DEFAULT_TIMEOUT_SECS,
            Some(value) => match value
                .as_u64()
                .ok_or_else(|| format!("timeout {value} is not a whole number of seconds"))
                .and_then(script_executor::check_timeout)
            {
                Ok(secs) => secs,
                Err(message) => {
                    self.send_response_for_seq(
                        seq,
                        json!({
                            "type": "response",
                            "request_seq": seq,
                            "success": false,
                            "command": "ct/exec-script",
                            "message": message,
                        }),
                    );
                    return Ok(());
                }
            },
        };

        // --- The host-read setting the script's trace session uses ---
        //
        // The script's Python process opens the trace through this daemon
        // like any other client, so it must ask for the session this
        // request's client asked for; otherwise a script started by a
        // client with host reads off would reach a backend that reads them.
        let host_source_reads = HostSourceReads::from_request(args);

        // --- Extract optional session ID ---
        let session_id = args
            .and_then(|a| a.get("sessionId"))
            .and_then(Value::as_str)
            .map(|s| s.to_string());

        // --- Determine the daemon socket path ---
        //
        // The Python subprocess connects back to the daemon using this socket.
        // It is the path this daemon bound, resolved by the same function
        // (`DaemonConfig::daemon_paths`) from the daemon state's config; a
        // manager without daemon state has no override, so the defaults.
        // `Paths` is never mutated, so a poisoned lock still holds a valid
        // value.
        let socket_path = {
            let no_override = DaemonConfig::default();
            let config = self
                .daemon_state
                .as_ref()
                .map_or(&no_override, |ds| &ds.config);
            let defaults = CODETRACER_PATHS
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            config
                .daemon_paths(&defaults)
                .socket
                .to_string_lossy()
                .to_string()
        };

        // --- Determine the Python API path ---
        //
        // `CODETRACER_PYTHON_API_PATH` wins when set; otherwise the package
        // is looked for in the known layouts around this binary (an install
        // prefix, or a build directory inside a checkout) and, in debug
        // builds, in the checkout it was compiled from, each subject to an
        // ownership and permission check.  See
        // `script_executor::resolve_python_api_path`.  A wrong explicit value
        // is refused here, before a Python process is spawned, so the caller
        // sees which setting to fix.
        let python_api = match script_executor::resolve_python_api_path(
            std::env::var(script_executor::PYTHON_API_PATH_ENV)
                .ok()
                .as_deref(),
            std::env::current_exe().ok().as_deref(),
            script_executor::COMPILED_CHECKOUT.map(std::path::Path::new),
        ) {
            Ok(lookup) => {
                for refused in &lookup.refused {
                    warn!("exec_script: ignored an untrusted Python API copy: {refused}");
                }
                lookup
            }
            Err(message) => {
                let response = json!({
                    "type": "response",
                    "request_seq": seq,
                    "success": false,
                    "command": "ct/exec-script",
                    "message": message,
                });
                self.send_response_for_seq(seq, response);
                return Ok(());
            }
        };

        // --- Confined unless its client opted out ---
        //
        // `unconfinedScripts: true` is sent only by a client started with the
        // explicit opt-in (`trace mcp --allow-unconfined-scripts`, or the `ct
        // trace` command line, which runs the user's own script).  Without
        // it the script runs confined, and where confinement is not
        // available it does not run at all.
        let unconfined = args
            .and_then(|a| a.get("unconfinedScripts"))
            .and_then(Value::as_bool)
            == Some(true);
        let refuse = |this: &Self, message: String| {
            this.send_response_for_seq(
                seq,
                json!({
                    "type": "response",
                    "request_seq": seq,
                    "success": false,
                    "command": "ct/exec-script",
                    "message": message,
                }),
            );
        };
        #[cfg_attr(not(unix), allow(unused_mut))]
        let mut confined_run: Option<(u64, crate::script_confinement::Scratch)> = None;
        let isolation = if unconfined {
            script_executor::ScriptIsolation::Unconfined {
                socket_path: socket_path.clone(),
            }
        } else {
            #[cfg(unix)]
            {
                let prepared = crate::script_confinement::probe()
                    .and_then(|()| {
                        let parent = CODETRACER_PATHS
                            .lock()
                            .unwrap_or_else(std::sync::PoisonError::into_inner)
                            .tmp_path
                            .join("script-scratch");
                        crate::script_confinement::make_scratch(&parent)
                    })
                    .and_then(|scratch| {
                        // The rule is bound to the directory's descriptor,
                        // and so is the script's working directory; the
                        // removal is relative to the scratch root's.
                        match crate::script_confinement::Confinement::prepare(&scratch) {
                            Ok(confinement) => match scratch.dir.try_clone() {
                                Ok(dir) => Ok((scratch, dir, confinement)),
                                Err(e) => {
                                    crate::script_confinement::remove_scratch(scratch);
                                    Err(format!("cannot keep the scratch directory open: {e}"))
                                }
                            },
                            Err(e) => {
                                crate::script_confinement::remove_scratch(scratch);
                                Err(e)
                            }
                        }
                    });
                let (scratch, scratch_dir, confinement) = match prepared {
                    Ok(prepared) => prepared,
                    Err(reason) => {
                        refuse(
                            self,
                            format!(
                                "exec_script runs scripts confined, and confinement is not \
                                 available here: {reason}. A server started with \
                                 --allow-unconfined-scripts runs scripts with its own \
                                 privileges instead"
                            ),
                        );
                        return Ok(());
                    }
                };
                let grant = ScriptGrant {
                    trace_path: canonical_trace_path(&trace_path_str),
                    host_source_reads,
                };
                let (client_id, daemon) = match self.register_script_client(grant) {
                    Ok(registered) => registered,
                    Err(reason) => {
                        crate::script_confinement::remove_scratch(scratch);
                        refuse(
                            self,
                            format!("exec_script cannot run a confined script: {reason}"),
                        );
                        return Ok(());
                    }
                };
                let scratch_path = scratch.path.clone();
                confined_run = Some((client_id, scratch));
                script_executor::ScriptIsolation::Confined {
                    confinement,
                    scratch: scratch_path,
                    scratch_dir,
                    daemon,
                }
            }
            #[cfg(not(unix))]
            {
                refuse(
                    self,
                    format!(
                        "exec_script runs scripts confined, and confinement is not available \
                         here: {}. A server started with --allow-unconfined-scripts runs \
                         scripts with its own privileges instead",
                        crate::script_confinement::probe().unwrap_err()
                    ),
                );
                return Ok(());
            }
        };
        let manager = self
            .daemon_state
            .as_ref()
            .map(|ds| ds.self_ref.clone())
            .unwrap_or_default();

        info!(
            "Executing script for trace={trace_path_str}, timeout={timeout_secs}s, \
             socket={socket_path}, confined={}, python_api={python_api:?}",
            !unconfined
        );

        // --- Clone the response sender so the spawned task can send the
        //     result without holding the BackendManager mutex. ---
        //
        // In daemon mode we clone the client's `UnboundedSender<Value>`.
        // In legacy (single-client) mode we clone the `manager_sender`.
        let client_id = self.lookup_client_for_seq(seq);
        let response_tx: Option<ClientSender> = if self.daemon_state.is_some() {
            client_id.and_then(|cid| {
                self.daemon_state
                    .as_ref()
                    .and_then(|ds| ds.clients.get(&cid))
                    .map(|handle| handle.sender.clone())
            })
        } else {
            self.manager_sender.clone().map(ClientSender::new)
        };

        // --- Spawn a detached task that runs the script and sends the
        //     response.  This returns immediately, releasing the mutex. ---
        tokio::spawn(async move {
            let send_response = |response: Value| {
                if let Some(tx) = &response_tx {
                    if let Err(err) = tx.send(response) {
                        error!("ct/exec-script: failed to send response for seq {seq}: {err}");
                    }
                } else {
                    error!(
                        "ct/exec-script: no response channel for seq {seq} \
                         (client may have disconnected)"
                    );
                }
            };

            let outcome = script_executor::execute_script(
                &script,
                &trace_path_str,
                isolation,
                &python_api,
                timeout_secs,
                session_id.as_deref(),
                host_source_reads,
            )
            .await;
            // The run is over: its connection's grant is revoked (a process
            // it left behind holding the connection is answered nothing more)
            // and its scratch directory removed.
            if let Some((client_id, scratch)) = confined_run {
                if let Some(manager) = manager.upgrade() {
                    Self::remove_client(&manager, client_id).await;
                }
                crate::script_confinement::remove_scratch(scratch);
            }
            match outcome {
                Ok(result) => {
                    let response = json!({
                        "type": "response",
                        "request_seq": seq,
                        "success": true,
                        "command": "ct/exec-script",
                        "body": {
                            "stdout": result.stdout,
                            "stderr": result.stderr,
                            "exitCode": result.exit_code,
                            "timedOut": result.timed_out,
                            "outputLimitExceeded": result.output_limit_exceeded,
                        }
                    });
                    send_response(response);
                }
                Err(e) => {
                    let response = json!({
                        "type": "response",
                        "request_seq": seq,
                        "success": false,
                        "command": "ct/exec-script",
                        "message": format!("script execution failed: {e}")
                    });
                    send_response(response);
                }
            }
        });

        Ok(())
    }

    /// Handles `ct/close-trace` requests.
    ///
    /// Tears down a session: stops the backend and removes the session from
    /// the session manager.
    async fn handle_close_trace(
        &mut self,
        seq: i64,
        args: Option<&Value>,
    ) -> Result<(), Box<dyn Error>> {
        let trace_path_str = match args
            .and_then(|a| a.get("tracePath"))
            .and_then(Value::as_str)
        {
            Some(p) => p.to_string(),
            None => {
                let response = json!({
                    "type": "response",
                    "request_seq": seq,
                    "success": false,
                    "command": "ct/close-trace",
                    "message": "missing 'tracePath' in arguments"
                });
                self.send_response_for_seq(seq, response);
                return Ok(());
            }
        };

        let session = SessionKey::for_request(&trace_path_str, args);

        // Look up the session and remove it.
        let backend_id = self
            .daemon_state
            .as_mut()
            .and_then(|ds| ds.session_manager.remove_session(&session));

        match backend_id {
            Some(bid) => {
                // Stop the backend process.
                if let Err(e) = self.stop_replay(bid).await {
                    warn!("Failed to stop backend {bid} for {trace_path_str}: {e}");
                }

                let response = json!({
                    "type": "response",
                    "request_seq": seq,
                    "success": true,
                    "command": "ct/close-trace",
                    "body": {
                        "tracePath": trace_path_str,
                        "closed": true,
                    }
                });
                self.send_response_for_seq(seq, response);
            }
            None => {
                let response = json!({
                    "type": "response",
                    "request_seq": seq,
                    "success": false,
                    "command": "ct/close-trace",
                    "message": self.no_session_error_message(&trace_path_str)
                });
                self.send_response_for_seq(seq, response);
            }
        }
        Ok(())
    }

    /// Returns `true` if the child process for the given backend ID has exited.
    ///
    /// Used by the crash detection loop to identify crashed backends.
    pub fn is_child_dead(&mut self, backend_id: usize) -> Option<bool> {
        if let Some(child_opt) = self.children.get_mut(backend_id) {
            if let Some(child) = child_opt.as_mut() {
                match child.try_wait() {
                    Ok(Some(_status)) => Some(true), // exited
                    Ok(None) => Some(false),         // still running
                    Err(_) => Some(true),            // error checking = treat as dead
                }
            } else {
                None // slot is empty (already cleaned up)
            }
        } else {
            None // invalid ID
        }
    }

    pub async fn message(&self, id: usize, message: Value) -> Result<(), Box<dyn Error>> {
        self.check_id(id)?;
        match self.parent_senders.get(id).and_then(|tx| tx.as_ref()) {
            Some(sender) => {
                sender.send(message)?;
                Ok(())
            }
            None => Err(Box::new(InvalidID(id))),
        }
    }

    pub async fn message_selected(&self, message: Value) -> Result<(), Box<dyn Error>> {
        self.message(self.selected, message).await
    }
}

/// The test flag that makes `ct/open-trace` start its replay backend as
/// `<CODETRACER_REPLAY_SERVER_CMD> mock-dap-backend <socket>` (the session
/// manager's own DAP test double) instead of `<…> dap-server <socket>`.
/// `1` turns it on; unset, empty or `0` leaves the real `dap-server`.
pub const REPLAY_SERVER_MOCK_DAP_ENV: &str = "CODETRACER_REPLAY_SERVER_MOCK_DAP";

/// The subcommand `ct/open-trace` starts the replay backend with, given the
/// value of [`REPLAY_SERVER_MOCK_DAP_ENV`].
///
/// The mock is chosen only when that flag asks for it.  It used to be
/// inferred from the backend command containing `backend-manager` or
/// `session-manager`, so a real `replay-server` built under a directory
/// with either word in its name was started as `replay-server
/// mock-dap-backend`, which it does not have, and every trace open timed
/// out.  A value other than `1`, `0` or empty is refused rather than read
/// as either: a misspelt flag that quietly selected one backend would make
/// a test pass or fail for the wrong reason.
pub fn replay_backend_subcommand(
    mock_dap: Option<&std::ffi::OsStr>,
) -> Result<&'static str, String> {
    match mock_dap {
        None => Ok("dap-server"),
        Some(value) => match value.to_str() {
            Some("" | "0") => Ok("dap-server"),
            Some("1") => Ok("mock-dap-backend"),
            _ => Err(format!(
                "{REPLAY_SERVER_MOCK_DAP_ENV}={} is neither 1 nor 0",
                value.to_string_lossy()
            )),
        },
    }
}

#[cfg(test)]
mod replay_backend_subcommand_tests {
    use super::replay_backend_subcommand;
    use std::ffi::OsStr;

    #[test]
    fn the_real_dap_server_unless_the_flag_asks_for_the_mock() {
        assert_eq!(replay_backend_subcommand(None), Ok("dap-server"));
        assert_eq!(
            replay_backend_subcommand(Some(OsStr::new(""))),
            Ok("dap-server")
        );
        assert_eq!(
            replay_backend_subcommand(Some(OsStr::new("0"))),
            Ok("dap-server")
        );
        assert_eq!(
            replay_backend_subcommand(Some(OsStr::new("1"))),
            Ok("mock-dap-backend")
        );
    }

    #[test]
    fn a_value_that_is_neither_1_nor_0_is_refused_by_name() {
        let err = replay_backend_subcommand(Some(OsStr::new("yes"))).unwrap_err();
        assert!(
            err.contains("CODETRACER_REPLAY_SERVER_MOCK_DAP=yes"),
            "{err}"
        );
    }
}

#[cfg(test)]
mod replay_id_tag_tests {
    use super::{REPLAY_ID_TAG, tag_with_replay_id};
    use serde_json::json;

    #[test]
    fn a_replays_message_names_the_replay_and_keeps_its_fields() {
        let event =
            json!({"type": "event", "event": "ct/complete-move", "seq": 7, "body": {"x": 1}});
        let tagged = tag_with_replay_id(event, 3);
        assert_eq!(tagged[REPLAY_ID_TAG], json!(3));
        assert_eq!(tagged["event"], json!("ct/complete-move"));
        assert_eq!(tagged["seq"], json!(7));
        assert_eq!(tagged["body"], json!({"x": 1}));
    }

    #[test]
    fn a_message_that_is_not_an_object_passes_through() {
        assert_eq!(tag_with_replay_id(json!("raw"), 1), json!("raw"));
    }
}

/// `ct/py-run-tracepoints` is answered whichever way the backend's
/// `ct/run-tracepoints` ends.
///
/// Spec: codetracer-specs `spec/Architecture/CodeTracer-DAP-Extensions.md`,
/// "Every request is answered": a request the replay server cannot carry out
/// gets `success: false` and a `message`, never only logged. The session
/// manager's Python bridge is the client of that request, so the refusal has
/// to reach the Python client it was made for; it used to be consumed here,
/// and the client waited for ever.
///
/// These drive the daemon's real message router (`route_daemon_message`)
/// with the messages a replay server sends. No backend process is started:
/// what is under test is what the router does with each message, and the
/// client is the receiving end of the channel the daemon writes to.
#[cfg(test)]
mod py_run_tracepoints_answer_tests {
    use super::{BackendManager, ClientHandle, DaemonState};
    use crate::config::DaemonConfig;
    use crate::python_bridge::{PendingPyRequest, PendingPyRequestKind, PyBridgeState};
    use crate::session::SessionManager;
    use serde_json::{Value, json};
    use std::collections::HashMap;
    use std::time::Duration;
    use tokio::sync::mpsc::{self, UnboundedReceiver};

    const CLIENT: u64 = 7;
    const CLIENT_SEQ: i64 = 3;
    const BACKEND_SEQ: i64 = 1_000_005;

    /// A daemon with one Python client and its `ct/py-run-tracepoints`
    /// already forwarded to the backend as `ct/run-tracepoints`.
    fn daemon_awaiting_a_sweep() -> (BackendManager, UnboundedReceiver<Value>) {
        let (session_manager, _expiries) = SessionManager::new(Duration::from_secs(60), 4);
        let (tx, rx) = mpsc::unbounded_channel();
        let mut py_bridge = PyBridgeState::new();
        py_bridge.pending_requests.push(PendingPyRequest {
            kind: PendingPyRequestKind::RunTracepoints,
            client_id: CLIENT,
            original_seq: CLIENT_SEQ,
            backend_seq: BACKEND_SEQ,
            response_command: "ct/py-run-tracepoints".to_string(),
            expression: String::new(),
        });
        let manager = BackendManager {
            children: vec![],
            children_receivers: vec![],
            parent_senders: vec![],
            selected: 0,
            manager_receiver: None,
            manager_sender: None,
            daemon_state: Some(DaemonState {
                clients: HashMap::from([(
                    CLIENT,
                    ClientHandle {
                        sender: crate::backend_manager::ClientSender::new(tx),
                        script: None,
                    },
                )]),
                request_client_map: HashMap::new(),
                shutdown_tx: None,
                session_manager,
                config: DaemonConfig::default(),
                py_bridge,
                inbound_tx: None,
                next_client_id: std::sync::Arc::new(std::sync::atomic::AtomicU64::new(0)),
                next_daemon_seq: crate::backend_manager::DAEMON_SEQ_BASE,
                self_ref: std::sync::Weak::new(),
            }),
        };
        (manager, rx)
    }

    fn answer(success: bool, message: Option<&str>) -> Value {
        let mut answer = json!({
            "type": "response",
            "request_seq": BACKEND_SEQ,
            "success": success,
            "command": "ct/run-tracepoints",
            "body": {},
        });
        if let Some(message) = message {
            answer["message"] = json!(message);
        }
        answer
    }

    fn sent(rx: &mut UnboundedReceiver<Value>) -> Vec<Value> {
        std::iter::from_fn(|| rx.try_recv().ok()).collect()
    }

    fn nothing_pending(manager: &BackendManager) -> bool {
        manager
            .daemon_state
            .as_ref()
            .is_some_and(|ds| ds.py_bridge.pending_requests.is_empty())
    }

    #[test]
    fn a_refused_sweep_is_answered_to_the_python_client_as_an_error() {
        let (mut manager, mut rx) = daemon_awaiting_a_sweep();
        let refusal = "ct/run-tracepoints: the tracepoint thread has no trace loaded";
        manager.route_daemon_message(Some(0), &answer(false, Some(refusal)));

        let sent = sent(&mut rx);
        assert_eq!(
            sent.len(),
            1,
            "the refused sweep must be answered exactly once, got {sent:?}"
        );
        assert_eq!(sent[0]["type"], json!("response"));
        assert_eq!(sent[0]["command"], json!("ct/py-run-tracepoints"));
        assert_eq!(sent[0]["request_seq"], json!(CLIENT_SEQ));
        assert_eq!(sent[0]["success"], json!(false));
        let message = sent[0]["message"].as_str().unwrap_or_default();
        assert!(
            message.contains(refusal),
            "the answer must carry the backend's reason, got {message:?}"
        );
        assert!(
            nothing_pending(&manager),
            "the request must not stay pending"
        );
    }

    #[test]
    fn a_refusal_without_a_message_is_still_an_error_answer() {
        let (mut manager, mut rx) = daemon_awaiting_a_sweep();
        manager.route_daemon_message(Some(0), &answer(false, None));

        let sent = sent(&mut rx);
        assert_eq!(sent.len(), 1, "got {sent:?}");
        assert_eq!(sent[0]["success"], json!(false));
        assert!(
            sent[0]["message"]
                .as_str()
                .is_some_and(|m| m.contains("ct/run-tracepoints")),
            "the answer must name what failed, got {:?}",
            sent[0]
        );
    }

    #[test]
    fn a_success_without_its_results_event_is_not_left_unanswered() {
        let (mut manager, mut rx) = daemon_awaiting_a_sweep();
        manager.route_daemon_message(Some(0), &answer(true, None));

        let sent = sent(&mut rx);
        assert_eq!(sent.len(), 1, "got {sent:?}");
        assert_eq!(sent[0]["request_seq"], json!(CLIENT_SEQ));
        assert_eq!(sent[0]["success"], json!(false));
        assert!(
            sent[0]["message"]
                .as_str()
                .is_some_and(|m| m.contains("ct/tracepoint-results")),
            "the answer must say the results never came, got {:?}",
            sent[0]
        );
    }

    /// The order a sweep that succeeds keeps: its results event, then its
    /// answer. The client gets the results once, and the answer after them
    /// reaches no client.
    #[test]
    fn a_sweep_that_succeeds_is_answered_once_with_its_results() {
        let (mut manager, mut rx) = daemon_awaiting_a_sweep();
        let results = json!({
            "type": "event",
            "event": "ct/tracepoint-results",
            "body": {"sessionId": 1, "results": [], "errors": {}},
        });
        manager.route_daemon_message(Some(0), &results);
        manager.route_daemon_message(Some(0), &answer(true, None));

        let sent = sent(&mut rx);
        assert_eq!(sent.len(), 1, "got {sent:?}");
        assert_eq!(sent[0]["success"], json!(true));
        assert_eq!(sent[0]["body"]["results"], json!([]));
        assert!(nothing_pending(&manager), "the answer must be consumed");
    }
}

/// The daemon's dispatch step: a panic is contained to its own request, and
/// a confined script's connection is admitted only its own trace's queries.
/// Driven through [`BackendManager::dispatch_client_message`], the step the
/// dispatch loop runs for every message, on a daemon-mode manager with no
/// backend (none of these requests reaches one).
#[cfg(test)]
mod dispatch_step_tests {
    use super::*;

    // Managers in one process derive their socket names from PID and slot.
    #[cfg(unix)]
    static REPLAY_TEST_LOCK: Mutex<()> = Mutex::const_new(());

    fn daemon(
        clients: Vec<(u64, Option<ScriptGrant>)>,
    ) -> (BackendManager, Vec<UnboundedReceiver<Value>>) {
        let (session_manager, _expiries) = SessionManager::new(Duration::from_secs(60), 4);
        let (shutdown_tx, _shutdown_rx) = mpsc::unbounded_channel();
        let mut map = HashMap::new();
        let mut receivers = Vec::new();
        for (id, script) in clients {
            let (tx, rx) = mpsc::unbounded_channel();
            map.insert(
                id,
                ClientHandle {
                    sender: ClientSender::new(tx),
                    script,
                },
            );
            receivers.push(rx);
        }
        let manager = BackendManager {
            children: vec![],
            children_receivers: vec![],
            parent_senders: vec![],
            selected: 0,
            manager_receiver: None,
            manager_sender: None,
            daemon_state: Some(DaemonState {
                clients: map,
                request_client_map: HashMap::new(),
                shutdown_tx: Some(shutdown_tx),
                session_manager,
                config: DaemonConfig::default(),
                py_bridge: PyBridgeState::new(),
                inbound_tx: None,
                next_client_id: std::sync::Arc::new(std::sync::atomic::AtomicU64::new(0)),
                next_daemon_seq: DAEMON_SEQ_BASE,
                self_ref: std::sync::Weak::new(),
            }),
        };
        (manager, receivers)
    }

    fn request(command: &str, seq: i64, arguments: Value) -> Value {
        json!({"type": "request", "command": command, "seq": seq, "arguments": arguments})
    }

    fn drain(rx: &mut UnboundedReceiver<Value>) -> Vec<Value> {
        let mut out = Vec::new();
        while let Ok(message) = rx.try_recv() {
            out.push(message);
        }
        out
    }

    // No mock backend: the production CTFS writer produces the recording and
    // the real replay-server accepts and initializes it. The only fault seam
    // is a panic in open-trace, after spawn or after session registration.
    #[cfg(unix)]
    #[tokio::test]
    async fn t_a_panicking_daemon_handler_leaves_nothing_behind() {
        let _serial = REPLAY_TEST_LOCK.lock().await;
        use super::request_cleanup_harness as harness;
        // A red baseline run must clean up even when an assertion unwinds.
        struct Cleanup(BackendManager);
        impl std::ops::Deref for Cleanup {
            type Target = BackendManager;
            fn deref(&self) -> &BackendManager {
                &self.0
            }
        }
        impl std::ops::DerefMut for Cleanup {
            fn deref_mut(&mut self) -> &mut BackendManager {
                &mut self.0
            }
        }
        impl Drop for Cleanup {
            fn drop(&mut self) {
                for (id, child) in self.0.children.iter_mut().enumerate() {
                    if let Some(child) = child {
                        let pid = child.id();
                        let _ = child.start_kill();
                        if let Some(pid) = pid {
                            // SAFETY: this is our own child; a concurrent Tokio
                            // reap is harmless (waitpid then returns ECHILD).
                            unsafe {
                                libc::waitpid(pid as i32, std::ptr::null_mut(), 0);
                            }
                        }
                    }
                    let socket = CODETRACER_PATHS
                        .lock()
                        .unwrap()
                        .tmp_path
                        .join("session-manager")
                        .join(std::process::id().to_string())
                        .join(format!("{id}.sock"));
                    let _ = std::fs::remove_file(socket);
                }
            }
        }
        let replay = harness::replay_server();
        let (_root_guard, root) = harness::short_root("ct-panic-");
        let source = root.join("app.py");
        std::fs::write(&source, "def main():\n    total = 0\n    for i in range(3):\n        total += i\n    return total\n").unwrap();
        let trace = root.join("trace");
        std::fs::create_dir(&trace).unwrap();
        harness::write_recording(&trace, &root, &source, &[]);
        let (manager, mut rx) = daemon(vec![(7, None), (8, None)]);
        let mut manager = Cleanup(manager);
        let existing_trace = root.join("existing");
        std::fs::create_dir(&existing_trace).unwrap();
        harness::write_recording(&existing_trace, &root, &source, &[]);
        manager
            .dispatch_client_message(
                7,
                request(
                    "ct/open-trace",
                    9,
                    json!({"tracePath": existing_trace, "testReplayServerCommand": replay}),
                ),
            )
            .await;
        let control = drain(&mut rx[0]);
        assert_eq!(control.len(), 1, "{control:?}");
        assert_eq!(control[0]["success"], true, "{control:?}");
        assert_eq!(
            manager
                .daemon_state
                .as_ref()
                .unwrap()
                .session_manager
                .session_count(),
            1
        );
        assert_eq!(
            manager
                .children
                .iter()
                .filter(|child| child.is_some())
                .count(),
            1
        );
        let existing_key = SessionKey::for_request(existing_trace.to_str().unwrap(), None);
        manager
            .daemon_state
            .as_mut()
            .unwrap()
            .py_bridge
            .breakpoint_state_mut(&existing_key);
        manager.select_replay(0).unwrap();
        for (stage, kind) in [
            ("after-start", "panic"),
            ("after-register", "panic"),
            ("after-start", "error"),
            ("after-register", "error"),
        ] {
            let backend_id = manager.children.len();
            manager
                .dispatch_client_message(
                    7,
                    request(
                        "ct/open-trace",
                        10,
                        json!({"tracePath": trace, "testPanicStage": stage,
                       "testFailureKind": kind, "testReplayServerCommand": replay}),
                    ),
                )
                .await;
            let answers = drain(&mut rx[0]);
            assert_eq!(answers.len(), 1, "{answers:?}");
            assert_eq!(answers[0]["success"], false, "{answers:?}");
            let message = answers[0]["message"].as_str().unwrap();
            let pid: i32 = message
                .split("pid=")
                .nth(1)
                .unwrap_or_else(|| panic!("did not reach injected panic: {message}"))
                .parse()
                .unwrap();
            let child_gone = unsafe { libc::kill(pid, 0) } == -1
                && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH);
            let socket = CODETRACER_PATHS
                .lock()
                .unwrap()
                .tmp_path
                .join("session-manager")
                .join(std::process::id().to_string())
                .join(format!("{backend_id}.sock"));
            let socket_gone = !socket.exists();
            let sessions_gone = manager
                .daemon_state
                .as_ref()
                .unwrap()
                .session_manager
                .session_count()
                == 1;
            let preserved = manager
                .daemon_state
                .as_ref()
                .unwrap()
                .session_manager
                .has_session(&existing_key)
                && manager.children[0]
                    .as_ref()
                    .and_then(|child| child.id())
                    .is_some_and(|pid| unsafe { libc::kill(pid as i32, 0) } == 0);
            let selection_preserved = manager.selected == 0;
            let bridge_gone = manager
                .daemon_state
                .as_ref()
                .unwrap()
                .py_bridge
                .breakpoint_states
                .len()
                == 1
                && manager
                    .daemon_state
                    .as_ref()
                    .unwrap()
                    .py_bridge
                    .breakpoint_states
                    .contains_key(&existing_key);
            // Even the deliberately failing baseline run reaps its own child
            // and removes its socket before reporting the regression.
            let _ = manager.stop_replay(backend_id).await;
            let _ = std::fs::remove_file(&socket);
            if let Some(ds) = manager.daemon_state.as_mut() {
                for session in ds.session_manager.list_sessions() {
                    if session.backend_id >= backend_id {
                        ds.session_manager.remove_session(&session.key);
                        ds.py_bridge.breakpoint_states.remove(&session.key);
                    }
                }
            }
            assert!(preserved, "{stage}: pre-existing session was removed");
            assert!(
                selection_preserved,
                "{stage}: pre-existing backend was deselected"
            );
            assert!(
                child_gone,
                "{stage}: replay-server {pid} survives the failure answer"
            );
            assert!(socket_gone, "{stage}: {} survives", socket.display());
            assert!(sessions_gone, "{stage}: session survives");
            assert!(bridge_gone, "{stage}: Python bridge state survives");
            manager.select_replay(0).unwrap();
            manager
                .dispatch_client_message(8, request("ct/ping", 11, json!({})))
                .await;
            assert_eq!(drain(&mut rx[1])[0]["success"], true);
        }
        manager
            .dispatch_client_message(
                7,
                request(
                    "ct/open-trace",
                    12,
                    json!({"tracePath": trace, "testReplayServerCommand": replay}),
                ),
            )
            .await;
        let answers = drain(&mut rx[0]);
        let success = answers.len() == 1 && answers[0]["success"] == true;
        let sessions = manager
            .daemon_state
            .as_ref()
            .unwrap()
            .session_manager
            .session_count();
        let children = manager
            .children
            .iter()
            .filter(|child| child.is_some())
            .count();
        let id = manager.children.len() - 1;
        let _ = manager.stop_replay(id).await;
        assert!(success, "control did not open the recording: {answers:?}");
        // Cached-session requests can allocate bridge state too: that new
        // entry must roll back even though its older session survives.
        manager
            .daemon_state
            .as_mut()
            .unwrap()
            .py_bridge
            .breakpoint_states
            .remove(&existing_key);
        manager
            .dispatch_client_message(
                7,
                request(
                    "ct/open-trace",
                    13,
                    json!({"tracePath": existing_trace, "testPanicStage": "cached",
                   "testReplayServerCommand": replay}),
                ),
            )
            .await;
        let cached_failure = drain(&mut rx[0]);
        let cached_bridge_removed = !manager
            .daemon_state
            .as_ref()
            .unwrap()
            .py_bridge
            .breakpoint_states
            .contains_key(&existing_key);
        let existing_session_kept = manager
            .daemon_state
            .as_ref()
            .unwrap()
            .session_manager
            .has_session(&existing_key);
        let _ = manager.stop_replay(0).await;
        assert_eq!(cached_failure.len(), 1, "{cached_failure:?}");
        assert_eq!(cached_failure[0]["success"], false, "{cached_failure:?}");
        assert!(
            cached_bridge_removed,
            "cached request kept its new bridge entry"
        );
        assert!(
            existing_session_kept,
            "cached request removed its existing session"
        );
        assert_eq!(sessions, 2, "the control must add exactly one session");
        assert_eq!(children, 2, "the control must add exactly one backend");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_failed_backend_spawn_leaves_no_socket() {
        let _serial = REPLAY_TEST_LOCK.lock().await;
        let (mut manager, _rx) = daemon(vec![(7, None)]);
        for raw in [true, false] {
            let id = manager.children.len();
            let result = if raw {
                manager
                    .start_replay_raw("/nonexistent/ct-request-cleanup/replay-server", &[])
                    .await
                    .map(|(id, _, _)| id)
            } else {
                manager
                    .start_replay("/nonexistent/ct-request-cleanup/replay-server", &[])
                    .await
            };
            assert!(result.is_err(), "the nonexistent executable must fail");
            let socket = CODETRACER_PATHS
                .lock()
                .unwrap()
                .tmp_path
                .join("session-manager")
                .join(std::process::id().to_string())
                .join(format!("{id}.sock"));
            let absent = !socket.exists();
            let _ = std::fs::remove_file(&socket);
            assert!(absent, "a failed spawn leaves {}", socket.display());
        }
    }

    #[tokio::test]
    async fn a_panicking_handler_fails_its_own_request_only() {
        let (mut manager, mut rx) = daemon(vec![(7, None), (8, None)]);
        manager
            .dispatch_client_message(7, request("ct/test-panic", 11, json!({})))
            .await;
        let answers = drain(&mut rx[0]);
        assert_eq!(answers.len(), 1, "{answers:?}");
        assert_eq!(answers[0]["request_seq"], json!(11));
        assert_eq!(answers[0]["success"], json!(false));
        assert!(
            answers[0]["message"]
                .as_str()
                .unwrap()
                .contains("failed handling `ct/test-panic`: a test handler panicked"),
            "{answers:?}"
        );
        // The same manager answers the next request, from either client.
        for (client, seq) in [(7u64, 12i64), (8, 13)] {
            manager
                .dispatch_client_message(client, request("ct/ping", seq, json!({})))
                .await;
            let answers = drain(&mut rx[client as usize - 7]);
            assert_eq!(answers.len(), 1, "{answers:?}");
            assert_eq!(answers[0]["success"], json!(true), "{answers:?}");
            assert_eq!(answers[0]["body"]["pong"], json!(true));
        }
    }

    /// Two clients number their requests alike; each answer reaches the
    /// client that sent the request, with that client's own number, and no
    /// other client.  Before the daemon numbered requests itself, the second
    /// client's `seq` took the first one's route.
    #[tokio::test]
    async fn two_clients_with_the_same_seq_each_get_their_own_answer() {
        let (mut manager, mut rx) = daemon(vec![(1, None), (2, None)]);
        // A test-only deferred handler leaves each route pending, as a
        // backend that answers asynchronously does. A missing backend would
        // instead fail and consume the route immediately.
        for client in [1u64, 2] {
            manager
                .dispatch_client_message(client, request("ct/test-deferred-answer", 5, json!({})))
                .await;
        }
        let map = &manager.daemon_state.as_ref().unwrap().request_client_map;
        assert_eq!(map.get(&DAEMON_SEQ_BASE), Some(&1));
        assert_eq!(map.get(&(DAEMON_SEQ_BASE + 1)), Some(&2));
        // The backend's answers, in the daemon's numbering, reversed.
        for (daemon_seq, marker) in [(DAEMON_SEQ_BASE + 1, "two"), (DAEMON_SEQ_BASE, "one")] {
            manager.route_daemon_message(
                Some(0),
                &json!({"type": "response", "request_seq": daemon_seq, "success": true,
                        "command": "next", "body": {"for": marker}}),
            );
        }
        for (index, marker) in [(0usize, "one"), (1, "two")] {
            let answers = drain(&mut rx[index]);
            assert_eq!(answers.len(), 1, "client {}: {answers:?}", index + 1);
            assert_eq!(answers[0]["request_seq"], json!(5));
            assert_eq!(answers[0]["body"]["for"], json!(marker));
        }
    }

    #[tokio::test]
    async fn a_script_connection_is_admitted_only_its_own_traces_queries() {
        let dir = tempfile::tempdir().unwrap();
        let own = dir.path().join("own");
        let other = dir.path().join("other");
        std::fs::create_dir_all(&own).unwrap();
        std::fs::create_dir_all(&other).unwrap();
        let grant = ScriptGrant {
            trace_path: canonical_trace_path(own.to_str().unwrap()),
            host_source_reads: HostSourceReads::Refused,
        };
        let (mut manager, mut rx) = daemon(vec![(1, Some(grant.clone())), (2, None)]);
        let own_path = own.to_str().unwrap();
        let refused = [
            request("ct/start-replay", 1, json!(["/bin/sh", "-c", "true"])),
            request(
                "ct/exec-script",
                2,
                json!({"tracePath": own_path, "script": "pass"}),
            ),
            request("ct/daemon-shutdown", 3, json!({})),
            request(
                "ct/py-locals",
                4,
                json!({"tracePath": other.to_str().unwrap()}),
            ),
            request("ct/py-locals", 5, json!({})),
            request(
                "ct/py-memory-diff-record-vs-replay",
                6,
                json!({"recordTrace": other.to_str().unwrap()}),
            ),
            request("next", 7, json!({"threadId": 1})),
            json!({"type": "event", "event": "stopped"}),
        ];
        for message in refused {
            let answer = manager.admit_client_message(1, message.clone());
            assert!(
                matches!(answer, Err(Some(_))),
                "admitted {message}: {answer:?}"
            );
            manager.dispatch_client_message(1, message).await;
        }
        let answers = drain(&mut rx[0]);
        assert_eq!(answers.len(), 8, "{answers:?}");
        assert!(
            answers.iter().all(|a| a["success"] == json!(false)),
            "{answers:?}"
        );
        assert!(
            manager.daemon_state.as_ref().unwrap().shutdown_tx.is_some(),
            "the refused shutdown must not reach the handler"
        );
        // Its own trace's query is admitted, with the grant's host-read
        // setting whatever the script wrote; the same path through a
        // symlink-free spelling with `..` names the same trace.
        let spelled = format!("{}/../own", own_path);
        let admitted = manager
            .admit_client_message(
                1,
                request(
                    "ct/py-locals",
                    9,
                    json!({"tracePath": spelled, "hostSourceReads": true}),
                ),
            )
            .expect("its own trace");
        assert_eq!(admitted["arguments"]["hostSourceReads"], json!(false));
        // It is dispatched under the granted path, not the name the script
        // wrote: a symlink to its trace, which the script could repoint
        // after the check, is replaced by what it resolved to.
        let link = dir.path().join("link");
        std::os::unix::fs::symlink(&own, &link).unwrap();
        let admitted = manager
            .admit_client_message(
                1,
                request(
                    "ct/open-trace",
                    11,
                    json!({"tracePath": link.to_str().unwrap()}),
                ),
            )
            .expect("a symlink to its own trace");
        assert_eq!(
            admitted["arguments"]["tracePath"],
            json!(std::fs::canonicalize(&own).unwrap().to_str().unwrap())
        );
        let admitted = manager
            .admit_client_message(
                1,
                request(
                    "ct/py-memory-diff-record-vs-replay",
                    12,
                    json!({"recordTrace": link.to_str().unwrap()}),
                ),
            )
            .expect("recordTrace through a symlink");
        assert_eq!(
            admitted["arguments"]["recordTrace"],
            json!(std::fs::canonicalize(&own).unwrap().to_str().unwrap())
        );
        // A client that connected to the socket is not restricted.
        let plain = request("ct/daemon-status", 10, json!({}));
        assert_eq!(
            manager.admit_client_message(2, plain.clone()).unwrap(),
            plain
        );
        // A client no longer registered (a run that ended) is dropped.
        assert!(matches!(manager.admit_client_message(3, plain), Err(None)));
        // Broadcasts skip the script's connection.
        BackendManager::broadcast_to_clients(
            manager.daemon_state.as_ref().unwrap(),
            &json!({"type": "event", "event": "output"}),
        );
        assert!(drain(&mut rx[0]).is_empty());
        assert_eq!(drain(&mut rx[1]).len(), 1);
    }
}
