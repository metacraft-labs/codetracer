use std::{
    collections::HashMap, error::Error, fmt::Debug, path::PathBuf, sync::Arc, time::Duration,
};

use serde_json::{Value, json};
use tokio::{
    fs::{create_dir_all, remove_file},
    io::{AsyncReadExt, AsyncWriteExt, WriteHalf},
    net::{UnixListener, UnixStream},
    process::{Child, Command},
    sync::{
        Mutex,
        mpsc::{self, UnboundedReceiver, UnboundedSender},
    },
    time::sleep,
};

use crate::{
    config::DaemonConfig,
    dap_init,
    dap_parser::DapParser,
    errors::{InvalidID, SocketPathError},
    paths::CODETRACER_PATHS,
    python_bridge::{
        self, PendingPyNavState, PendingPyRequest, PendingPyRequestKind, PyBridgeState,
    },
    script_executor,
    session::SessionManager,
    trace_metadata,
};

/// Write handle for a single connected daemon client, together with its
/// unique identifier.  Used by the daemon-mode response router.
struct ClientHandle {
    /// Channel for sending DAP messages back to this client.
    tx: UnboundedSender<Value>,
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

// TODO: cleanup on exit
// TODO: Handle signals
impl BackendManager {
    // -----------------------------------------------------------------------
    // Legacy single-client constructor — UNCHANGED from the original code.
    // -----------------------------------------------------------------------

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
            socket_dir = path.tmp_path.join("backend-manager");
        }

        create_dir_all(&socket_dir).await?;

        let socket_path = socket_dir.join(std::process::id().to_string() + ".sock");
        _ = remove_file(&socket_path).await;

        let mut socket_read;
        let mut socket_write;

        info!("Socket listening on: {}", socket_path.display());

        let listener = UnixListener::bind(socket_path)?;
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
                for rx in res.children_receivers.iter_mut().flatten() {
                    if !rx.is_empty()
                        && let Some(message) = rx.recv().await
                    {
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
    /// - Auto-shutdown when the last session expires (if any sessions were
    ///   ever loaded).
    /// - Shut down cleanly when `ct/daemon-shutdown` is received or a signal
    ///   is caught (see `shutdown_rx`).
    ///
    /// Returns `(Arc<Mutex<BackendManager>>, UnboundedReceiver<()>)`.
    /// The receiver fires when a `ct/daemon-shutdown` request is received
    /// (or auto-shutdown triggers), allowing the caller (main.rs) to tear
    /// down the process.
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
            }),
        }));

        // Channel for the per-client read tasks to forward (client_id, message)
        // tuples into the central dispatch loop.
        let (inbound_tx, mut inbound_rx) = mpsc::unbounded_channel::<(u64, Value)>();

        // Ensure socket directory exists and remove any stale socket file.
        if let Some(parent) = socket_path.parent() {
            create_dir_all(parent).await?;
        }
        _ = remove_file(&socket_path).await;

        let listener = UnixListener::bind(&socket_path)?;
        info!("Daemon listening on: {}", socket_path.display());

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
                                ds.clients.insert(client_id, ClientHandle { tx: client_tx });
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

                // Track which client sent this request (if it has a seq number).
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

        Ok((mgr, shutdown_rx))
    }

    /// Spawns a task that reads DAP messages from a client's socket and forwards
    /// `(client_id, message)` tuples to the central dispatch channel.
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

                if let Some(ticks) = rr_ticks {
                    if let Some(pending) =
                        ds.py_bridge.pending_navigations.iter_mut().find(|p| {
                            p.backend_id == bid
                                && p.state == PendingPyNavState::AwaitingStackTrace
                        })
                    {
                        pending.rr_ticks = Some(ticks);
                    }
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

                if text.contains("End of record") || text.contains("Limit of record") {
                    if let Some(pending) =
                        ds.py_bridge.pending_navigations.iter_mut().find(|p| {
                            p.backend_id == bid
                                && (p.state == PendingPyNavState::AwaitingStopped
                                    || p.state == PendingPyNavState::AwaitingStackTrace)
                        })
                    {
                        pending.end_of_trace = true;
                    }
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
            // See: db-backend/src/task.rs — `FlowUpdate`, `FlowViewUpdate`
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
                    let is_error = body
                        .get("error")
                        .and_then(Value::as_bool)
                        .unwrap_or(false);

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
                        let view_updates = body
                            .get("viewUpdates")
                            .and_then(Value::as_array);

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
                let nav_success = msg
                    .get("success")
                    .and_then(Value::as_bool)
                    .unwrap_or(true);

                if nav_success {
                    // Silently consume — don't forward to any client.
                    // The subsequent `stopped` event will advance the
                    // state machine.
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
                let mut location = python_bridge::extract_location_from_stack_trace(msg);

                // Inject rrTicks captured from the ct/complete-move event if
                // the stackTrace response did not already include ticks.
                // The standard DAP stackTrace response does not carry ticks,
                // but the ct/complete-move event emitted by the CodeTracer
                // backend does, and we captured it earlier.
                if let Some(rr_ticks) = pending.rr_ticks {
                    let current_ticks = location
                        .get("ticks")
                        .and_then(Value::as_i64)
                        .unwrap_or(0);
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

                // Fire-and-forget requests: silently consume the backend
                // response without forwarding anything to the client.
                // This is used for setBreakpoints/setDataBreakpoints
                // commands whose results the client does not need.
                if pending.kind == PendingPyRequestKind::FireAndForget {
                    return;
                }

                let (success, body_or_error) = match pending.kind {
                    PendingPyRequestKind::Locals => python_bridge::format_locals_response(msg),
                    PendingPyRequestKind::Evaluate => python_bridge::format_evaluate_response(msg),
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
                    PendingPyRequestKind::FireAndForget => {
                        // Already handled above; unreachable.
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
                    if let Err(err) = handle.tx.send(msg.clone()) {
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
    fn broadcast_to_clients(ds: &DaemonState, msg: &Value) {
        for (cid, handle) in &ds.clients {
            if let Err(err) = handle.tx.send(msg.clone()) {
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
    async fn ttl_expiry_loop(mgr: Arc<Mutex<Self>>, mut ttl_expiry_rx: UnboundedReceiver<PathBuf>) {
        while let Some(trace_path) = ttl_expiry_rx.recv().await {
            let mut locked = mgr.lock().await;

            let ds = match locked.daemon_state.as_mut() {
                Some(ds) => ds,
                None => continue,
            };

            // Remove the session (this also aborts its timer, though the
            // timer already fired in this case).
            if let Some(backend_id) = ds.session_manager.remove_session(&trace_path) {
                info!(
                    "TTL expired for session {} (backend_id={backend_id})",
                    trace_path.display()
                );

                // Stop the child replay process.
                if let Err(e) = locked.stop_replay(backend_id).await {
                    warn!(
                        "Failed to stop replay {backend_id} for expired session {}: {e}",
                        trace_path.display()
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
            let sessions: Vec<(PathBuf, usize)> = {
                let ds = match locked.daemon_state.as_ref() {
                    Some(ds) => ds,
                    None => continue,
                };
                ds.session_manager
                    .list_sessions()
                    .iter()
                    .map(|s| (s.trace_path.clone(), s.backend_id))
                    .collect()
            };

            // Second pass: check which backends are dead (only borrows
            // locked.children, not daemon_state).
            let mut dead_sessions: Vec<(PathBuf, usize)> = Vec::new();
            for (path, backend_id) in &sessions {
                if let Some(true) = locked.is_child_dead(*backend_id) {
                    dead_sessions.push((path.clone(), *backend_id));
                }
            }

            // Third pass: clean up dead sessions.
            for (path, backend_id) in dead_sessions {
                warn!(
                    "Crash detected for backend {backend_id} (trace: {})",
                    path.display()
                );

                if let Some(ds) = locked.daemon_state.as_mut() {
                    ds.session_manager.remove_session(&path);

                    // Broadcast an error event to all clients.
                    let event = json!({
                        "type": "event",
                        "event": "ct/session-crashed",
                        "body": {
                            "tracePath": path.to_string_lossy(),
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

    /// In daemon mode, sends a message directly to a specific client
    /// (bypassing the manager_sender channel).
    fn send_to_client(&self, client_id: u64, message: Value) {
        if let Some(ds) = &self.daemon_state {
            if let Some(handle) = ds.clients.get(&client_id) {
                if let Err(err) = handle.tx.send(message) {
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
        let socket_dir: std::path::PathBuf;
        {
            let path = &CODETRACER_PATHS.lock()?.tmp_path;
            socket_dir = path
                .join("backend-manager")
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

        let listener = UnixListener::bind(socket_path)?;

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

        match listener.accept().await {
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

        if let Some(child_opt) = self.children.get_mut(id) {
            if let Some(subprocess) = child_opt.as_mut() {
                let _ = subprocess.kill().await.map_err(|e| {
                    warn!("can't stop subprocess: {e:?}");
                    e
                });
            }
            *child_opt = None;
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
        self.selected = usize::MAX;

        info!("Stopped replay {id}");

        Ok(())
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
                            let trace_path = Self::trace_path_from_args(command, &cmd_args);

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
                                        let client_id = self.lookup_client_for_seq(seq);
                                        if let Some(cid) = client_id {
                                            self.send_to_client(cid, response);
                                        } else {
                                            self.send_manager_message(response);
                                        }
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
                                    let client_id = self.lookup_client_for_seq(seq);
                                    if let Some(cid) = client_id {
                                        self.send_to_client(cid, response);
                                    } else {
                                        self.send_manager_message(response);
                                    }
                                    return Ok(());
                                }
                            }

                            let replay_id = self.start_replay(command, &cmd_args).await?;

                            // Register the session in the session manager.
                            if let Some(ds) = self.daemon_state.as_mut()
                                && let Err(e) = ds
                                    .session_manager
                                    .add_session(trace_path.clone(), replay_id)
                            {
                                warn!(
                                    "Failed to register session for {}: {e}",
                                    trace_path.display()
                                );
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
                            let client_id = self.lookup_client_for_seq(seq);
                            if self.daemon_state.is_some() {
                                if let Some(cid) = client_id {
                                    self.send_to_client(cid, response);
                                } else {
                                    self.send_manager_message(response);
                                }
                            } else {
                                self.send_manager_message(response);
                            }
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
                                .map(|s| Value::String(s.trace_path.to_string_lossy().to_string()))
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
                    "ct/py-calltrace" => self.handle_py_calltrace(seq, args).await,
                    "ct/py-search-calltrace" => self.handle_py_search_calltrace(seq, args).await,
                    "ct/py-events" => self.handle_py_events(seq, args).await,
                    "ct/py-terminal" => self.handle_py_terminal(seq, args).await,
                    "ct/py-read-source" => self.handle_py_read_source(seq, args).await,
                    "ct/py-processes" => self.handle_py_processes(seq, args).await,
                    "ct/py-select-process" => self.handle_py_select_process(seq, args).await,
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
                            // Reset TTL for the session that owns this replay.
                            self.reset_ttl_for_backend_id(backend_id);
                            return self.message(backend_id, message).await;
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

        let trace_path = PathBuf::from(&trace_path_str);

        // Look up the backend for this trace.
        let backend_id = match self
            .daemon_state
            .as_ref()
            .and_then(|ds| ds.session_manager.get_session_backend_id(&trace_path))
        {
            Some(id) => id,
            None => {
                self.send_py_error(seq, &format!("no session loaded for {trace_path_str}"));
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

        // Build DAP request arguments.
        // For goto_ticks, include the ticks value; for all others, just threadId.
        let dap_args = if method == "goto_ticks" {
            let ticks = args
                .and_then(|a| a.get("ticks"))
                .and_then(Value::as_i64)
                .unwrap_or(0);
            serde_json::json!({"threadId": 1, "ticks": ticks})
        } else {
            serde_json::json!({"threadId": 1})
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
    fn backend_id_for_trace(&self, trace_path: &PathBuf) -> Option<usize> {
        self.daemon_state
            .as_ref()
            .and_then(|ds| ds.session_manager.get_session_backend_id(trace_path))
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

        let trace_path = PathBuf::from(&trace_path_str);

        let backend_id = match self.backend_id_for_trace(&trace_path) {
            Some(id) => id,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-locals",
                    &format!("no session loaded for {trace_path_str}"),
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
        let lang = args
            .and_then(|a| a.get("lang"))
            .and_then(Value::as_i64)
            .unwrap_or(0);

        // Get a unique seq for the DAP command sent to the backend.
        let dap_seq = match self.daemon_state.as_mut() {
            Some(ds) => ds.py_bridge.next_seq(),
            None => return Ok(()),
        };

        // Build and send the ct/load-locals command to the backend.
        //
        // The arguments must match the backend's `CtLoadLocalsArguments`
        // schema (camelCase):
        //   https://github.com/nicholasgasior/codetracer/blob/main/codetracer/src/db-backend/src/task.rs
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

        let trace_path = PathBuf::from(&trace_path_str);

        let backend_id = match self.backend_id_for_trace(&trace_path) {
            Some(id) => id,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-evaluate",
                    &format!("no session loaded for {trace_path_str}"),
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
                "lang": 0,
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

        let trace_path = PathBuf::from(&trace_path_str);

        let backend_id = match self.backend_id_for_trace(&trace_path) {
            Some(id) => id,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-stack-trace",
                    &format!("no session loaded for {trace_path_str}"),
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

        let trace_path = PathBuf::from(&trace_path_str);

        let backend_id = match self.backend_id_for_trace(&trace_path) {
            Some(id) => id,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-flow",
                    &format!("no session loaded for {trace_path_str}"),
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
        // See: db-backend/src/task.rs — `enum FlowMode`
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
        // See: db-backend/src/task.rs — `CtLoadFlowArguments`, `Location`
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
    /// `setBreakpoints` command to the backend (fire-and-forget), and
    /// immediately returns the assigned breakpoint ID to the client.
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
    /// **Response:**
    /// ```json
    /// {
    ///   "type": "response",
    ///   "request_seq": 1,
    ///   "success": true,
    ///   "command": "ct/py-add-breakpoint",
    ///   "body": {"breakpointId": 1}
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

        let trace_path = PathBuf::from(&trace_path_str);

        let backend_id = match self.backend_id_for_trace(&trace_path) {
            Some(id) => id,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-add-breakpoint",
                    &format!("no session loaded for {trace_path_str}"),
                );
                return Ok(());
            }
        };

        self.reset_ttl_for_backend_id(backend_id);

        // Update the breakpoint state and get the full list for the file.
        let (bp_id, all_lines) = match self.daemon_state.as_mut() {
            Some(ds) => {
                let bp_state = ds.py_bridge.breakpoint_state_mut(&trace_path);
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

        // Fire-and-forget: send the DAP command but register a pending
        // request so the response router silently consumes the backend's
        // response instead of forwarding it to the client.
        let _ = self.message(backend_id, dap_request).await;
        if let Some(ds) = self.daemon_state.as_mut() {
            ds.py_bridge.pending_requests.push(PendingPyRequest {
                kind: PendingPyRequestKind::FireAndForget,
                client_id: 0,
                original_seq: 0,
                backend_seq: dap_seq,
                response_command: String::new(),
            });
        }

        // Respond to the client immediately with the breakpoint ID.
        let response = json!({
            "type": "response",
            "request_seq": seq,
            "success": true,
            "command": "ct/py-add-breakpoint",
            "body": {"breakpointId": bp_id}
        });
        self.send_response_for_seq(seq, response);
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

        let trace_path = PathBuf::from(&trace_path_str);

        let backend_id = match self.backend_id_for_trace(&trace_path) {
            Some(id) => id,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-remove-breakpoint",
                    &format!("no session loaded for {trace_path_str}"),
                );
                return Ok(());
            }
        };

        self.reset_ttl_for_backend_id(backend_id);

        // Remove the breakpoint and get remaining lines for the affected file.
        let removal_result = match self.daemon_state.as_mut() {
            Some(ds) => {
                let bp_state = ds.py_bridge.breakpoint_state_mut(&trace_path);
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
                        kind: PendingPyRequestKind::FireAndForget,
                        client_id: 0,
                        original_seq: 0,
                        backend_seq: dap_seq,
                        response_command: String::new(),
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

        let trace_path = PathBuf::from(&trace_path_str);

        let backend_id = match self.backend_id_for_trace(&trace_path) {
            Some(id) => id,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-add-watchpoint",
                    &format!("no session loaded for {trace_path_str}"),
                );
                return Ok(());
            }
        };

        self.reset_ttl_for_backend_id(backend_id);

        // Update the watchpoint state.
        let (wp_id, all_expressions) = match self.daemon_state.as_mut() {
            Some(ds) => {
                let bp_state = ds.py_bridge.breakpoint_state_mut(&trace_path);
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

        let _ = self.message(backend_id, dap_request).await;
        if let Some(ds) = self.daemon_state.as_mut() {
            ds.py_bridge.pending_requests.push(PendingPyRequest {
                kind: PendingPyRequestKind::FireAndForget,
                client_id: 0,
                original_seq: 0,
                backend_seq: dap_seq,
                response_command: String::new(),
            });
        }

        let response = json!({
            "type": "response",
            "request_seq": seq,
            "success": true,
            "command": "ct/py-add-watchpoint",
            "body": {"watchpointId": wp_id}
        });
        self.send_response_for_seq(seq, response);
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

        let trace_path = PathBuf::from(&trace_path_str);

        let backend_id = match self.backend_id_for_trace(&trace_path) {
            Some(id) => id,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-remove-watchpoint",
                    &format!("no session loaded for {trace_path_str}"),
                );
                return Ok(());
            }
        };

        self.reset_ttl_for_backend_id(backend_id);

        let removal_result = match self.daemon_state.as_mut() {
            Some(ds) => {
                let bp_state = ds.py_bridge.breakpoint_state_mut(&trace_path);
                bp_state.remove_watchpoint(wp_id)
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
                let _ = self.message(backend_id, dap_request).await;
                if let Some(ds) = self.daemon_state.as_mut() {
                    ds.py_bridge.pending_requests.push(PendingPyRequest {
                        kind: PendingPyRequestKind::FireAndForget,
                        client_id: 0,
                        original_seq: 0,
                        backend_seq: dap_seq,
                        response_command: String::new(),
                    });
                }

                let response = json!({
                    "type": "response",
                    "request_seq": seq,
                    "success": true,
                    "command": "ct/py-remove-watchpoint",
                    "body": {"removed": true}
                });
                self.send_response_for_seq(seq, response);
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

        let trace_path = PathBuf::from(&trace_path_str);

        let backend_id = match self.backend_id_for_trace(&trace_path) {
            Some(id) => id,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-calltrace",
                    &format!("no session loaded for {trace_path_str}"),
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
        let dap_request = serde_json::json!({
            "type": "request",
            "command": "ct/load-calltrace-section",
            "seq": dap_seq,
            "arguments": {
                "start": start,
                "count": count,
                "depth": depth,
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
        let limit = args
            .and_then(|a| a.get("limit"))
            .and_then(Value::as_i64)
            .unwrap_or(100);

        let trace_path = PathBuf::from(&trace_path_str);

        let backend_id = match self.backend_id_for_trace(&trace_path) {
            Some(id) => id,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-search-calltrace",
                    &format!("no session loaded for {trace_path_str}"),
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
        let dap_request = serde_json::json!({
            "type": "request",
            "command": "ct/search-calltrace",
            "seq": dap_seq,
            "arguments": {
                "query": query,
                "limit": limit,
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

        let trace_path = PathBuf::from(&trace_path_str);

        let backend_id = match self.backend_id_for_trace(&trace_path) {
            Some(id) => id,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-events",
                    &format!("no session loaded for {trace_path_str}"),
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

        let trace_path = PathBuf::from(&trace_path_str);

        let backend_id = match self.backend_id_for_trace(&trace_path) {
            Some(id) => id,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-terminal",
                    &format!("no session loaded for {trace_path_str}"),
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
            });
        }

        Ok(())
    }

    /// Handles `ct/py-read-source` requests from Python clients.
    ///
    /// Translates the request into a `ct/read-source` DAP command,
    /// sends it to the backend, and registers a pending request.
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

        let trace_path = PathBuf::from(&trace_path_str);

        let backend_id = match self.backend_id_for_trace(&trace_path) {
            Some(id) => id,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-read-source",
                    &format!("no session loaded for {trace_path_str}"),
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

        // Build and send the ct/read-source command to the backend.
        let dap_request = serde_json::json!({
            "type": "request",
            "command": "ct/read-source",
            "seq": dap_seq,
            "arguments": {
                "path": source_path,
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

        let trace_path = PathBuf::from(&trace_path_str);

        let backend_id = match self.backend_id_for_trace(&trace_path) {
            Some(id) => id,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-processes",
                    &format!("no session loaded for {trace_path_str}"),
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

        let trace_path = PathBuf::from(&trace_path_str);

        let backend_id = match self.backend_id_for_trace(&trace_path) {
            Some(id) => id,
            None => {
                self.send_py_command_error(
                    seq,
                    "ct/py-select-process",
                    &format!("no session loaded for {trace_path_str}"),
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
            });
        }

        Ok(())
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

        // Check if already loaded — return existing session and reset TTL.
        if let Some(ds) = self.daemon_state.as_mut()
            && ds.session_manager.has_session(&trace_path)
        {
            ds.session_manager.reset_ttl(&trace_path);
            if let Some(info) = ds.session_manager.get_session(&trace_path) {
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

        // Determine which backend command to spawn.
        // Tests can override via CODETRACER_DB_BACKEND_CMD env var.
        let backend_cmd =
            std::env::var("CODETRACER_DB_BACKEND_CMD").unwrap_or_else(|_| "db-backend".to_string());

        // Build the arguments: the backend command + "dap-server" subcommand.
        let backend_args_owned: Vec<String> = if backend_cmd.contains("backend-manager") {
            // For mock-dap-backend, the subcommand is `mock-dap-backend`.
            vec!["mock-dap-backend".to_string()]
        } else {
            vec!["dap-server".to_string()]
        };
        let backend_args: Vec<&str> = backend_args_owned.iter().map(|s| s.as_str()).collect();

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

        // Build DAP launch options.  If the trace directory contains an `rr/`
        // subdirectory, we need to tell db-backend where `ct-rr-support` is so
        // it can spawn the RR replay worker.
        //
        // The `ct-rr-support` path is resolved from (in priority order):
        //   1. `CODETRACER_CT_RR_SUPPORT_CMD` environment variable
        //   2. `ct-rr-support` on PATH
        //
        // Reference: db-backend/src/dap.rs — `LaunchRequestArguments.ctRRWorkerExe`
        let dap_launch_opts = {
            let mut opts = dap_init::DapLaunchOptions::default();
            if trace_path.join("rr").is_dir() {
                let rr_support_cmd = std::env::var("CODETRACER_CT_RR_SUPPORT_CMD")
                    .ok()
                    .map(PathBuf::from)
                    .or_else(|| {
                        // Try to find ct-rr-support on PATH.
                        std::process::Command::new("which")
                            .arg("ct-rr-support")
                            .output()
                            .ok()
                            .filter(|o| o.status.success())
                            .and_then(|o| {
                                let s = String::from_utf8_lossy(&o.stdout).trim().to_string();
                                if s.is_empty() { None } else { Some(PathBuf::from(s)) }
                            })
                    });

                if let Some(ref exe) = rr_support_cmd {
                    info!(
                        "RR trace detected, using ct-rr-support: {}",
                        exe.display()
                    );
                    opts.ct_rr_worker_exe = rr_support_cmd;
                } else {
                    warn!(
                        "RR trace detected at {} but ct-rr-support not found; \
                         DAP init may fail",
                        trace_path.display()
                    );
                }
            }
            opts
        };

        // Run DAP init sequence.
        let dap_timeout = Duration::from_secs(30);
        match dap_init::run_dap_init(&sender, &mut receiver, &trace_path, dap_timeout, &dap_launch_opts).await {
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
            && let Err(e) = ds.session_manager.add_session_with_metadata(
                trace_path.clone(),
                backend_id,
                &metadata,
            )
        {
            warn!(
                "Failed to register session for {}: {e}",
                trace_path.display()
            );
        }

        let response = json!({
            "type": "response",
            "request_seq": seq,
            "success": true,
            "command": "ct/open-trace",
            "body": {
                "tracePath": trace_path_str,
                "backendId": backend_id,
                "language": metadata.language,
                "totalEvents": metadata.total_events,
                "sourceFiles": metadata.source_files,
                "program": metadata.program,
                "workdir": metadata.workdir,
                "cached": false,
                "initialLocation": initial_location,
            }
        });
        self.send_response_for_seq(seq, response);
        Ok(())
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

        let trace_path = PathBuf::from(&trace_path_str);

        let session_info = self
            .daemon_state
            .as_ref()
            .and_then(|ds| ds.session_manager.get_session(&trace_path));

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
                    "message": format!("no session loaded for {trace_path_str}")
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
    fn handle_exec_script(&self, seq: i64, args: Option<&Value>) -> Result<(), Box<dyn Error>> {
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

        // --- Extract optional timeout ---
        let timeout_secs = args
            .and_then(|a| a.get("timeout"))
            .and_then(Value::as_u64)
            .unwrap_or(script_executor::DEFAULT_TIMEOUT_SECS);

        // --- Determine the daemon socket path ---
        //
        // The Python subprocess connects back to the daemon using this socket.
        // In daemon mode we use the socket path from the daemon state config;
        // otherwise fall back to the well-known default.
        let socket_path = self
            .daemon_state
            .as_ref()
            .and_then(|ds| ds.config.socket_path.as_ref())
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_else(|| {
                CODETRACER_PATHS
                    .lock()
                    .map(|p| p.daemon_socket_path().to_string_lossy().to_string())
                    .unwrap_or_else(|_| "/tmp/codetracer/daemon.sock".to_string())
            });

        // --- Determine the Python API path ---
        //
        // The `CODETRACER_PYTHON_API_PATH` environment variable points to the
        // directory containing the `codetracer` Python package.  If not set we
        // try a relative path from the backend-manager binary that works in
        // the standard repository layout.
        let python_api_path = std::env::var("CODETRACER_PYTHON_API_PATH").unwrap_or_else(|_| {
            // Attempt to resolve from the binary location:
            // <repo>/src/backend-manager/target/<profile>/backend-manager
            //  -> <repo>/python-api/
            if let Ok(exe) = std::env::current_exe()
                && let Some(repo) = exe
                    .parent() // target/<profile>/
                    .and_then(|p| p.parent()) // target/
                    .and_then(|p| p.parent()) // src/backend-manager/
                    .and_then(|p| p.parent()) // src/
                    .and_then(|p| p.parent())
            // <repo>/
            {
                let api = repo.join("python-api");
                if api.exists() {
                    return api.to_string_lossy().to_string();
                }
            }
            // Last resort: assume it is installed or on PYTHONPATH already.
            String::new()
        });

        info!(
            "Executing script for trace={trace_path_str}, timeout={timeout_secs}s, \
             socket={socket_path}, python_api={python_api_path}"
        );

        // --- Clone the response sender so the spawned task can send the
        //     result without holding the BackendManager mutex. ---
        //
        // In daemon mode we clone the client's `UnboundedSender<Value>`.
        // In legacy (single-client) mode we clone the `manager_sender`.
        let client_id = self.lookup_client_for_seq(seq);
        let response_tx: Option<UnboundedSender<Value>> = if self.daemon_state.is_some() {
            client_id.and_then(|cid| {
                self.daemon_state
                    .as_ref()
                    .and_then(|ds| ds.clients.get(&cid))
                    .map(|handle| handle.tx.clone())
            })
        } else {
            self.manager_sender.clone()
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

            match script_executor::execute_script(
                &script,
                &trace_path_str,
                &socket_path,
                &python_api_path,
                timeout_secs,
            )
            .await
            {
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

        let trace_path = PathBuf::from(&trace_path_str);

        // Look up the session and remove it.
        let backend_id = self
            .daemon_state
            .as_mut()
            .and_then(|ds| ds.session_manager.remove_session(&trace_path));

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
                    "message": format!("no session loaded for {trace_path_str}")
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
