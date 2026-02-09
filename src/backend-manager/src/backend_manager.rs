use std::{collections::HashMap, error::Error, fmt::Debug, path::PathBuf, sync::Arc, time::Duration};

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
    dap_parser::DapParser,
    errors::{InvalidID, SocketPathError},
    paths::CODETRACER_PATHS,
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
}

impl Debug for DaemonState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DaemonState")
            .field("num_clients", &self.clients.len())
            .field("pending_requests", &self.request_client_map.len())
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
    /// - Shut down cleanly when `ct/daemon-shutdown` is received or a signal
    ///   is caught (see `shutdown_rx`).
    ///
    /// Returns `(Arc<Mutex<BackendManager>>, UnboundedReceiver<()>)`.
    /// The receiver fires when a `ct/daemon-shutdown` request is received,
    /// allowing the caller (main.rs) to tear down the process.
    pub async fn new_daemon(
        socket_path: PathBuf,
    ) -> Result<(Arc<Mutex<Self>>, UnboundedReceiver<()>), Box<dyn Error>> {
        let (shutdown_tx, shutdown_rx) = mpsc::unbounded_channel::<()>();

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
                        Self::spawn_client_reader(client_id, read_half, inbound_tx.clone(), mgr_accept.clone());
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
        //     routes responses to the correct client and broadcasts events. ---
        let mgr_router = mgr.clone();
        tokio::spawn(async move {
            loop {
                sleep(Duration::from_millis(10)).await;

                let mut locked = mgr_router.lock().await;

                // Collect messages from child receivers.
                let mut outbound: Vec<Value> = Vec::new();
                for rx in locked.children_receivers.iter_mut().flatten() {
                    while !rx.is_empty() {
                        if let Some(msg) = rx.recv().await {
                            outbound.push(msg);
                        }
                    }
                }

                // Collect messages from manager_receiver.
                if let Some(manager_rx) = locked.manager_receiver.as_mut() {
                    while !manager_rx.is_empty() {
                        if let Some(msg) = manager_rx.recv().await {
                            outbound.push(msg);
                        }
                    }
                }

                // Route each outbound message to the appropriate client(s).
                for msg in outbound {
                    locked.route_daemon_message(&msg);
                }
            }
        });

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
            info!("Daemon: removed client {client_id}, {} remaining", ds.clients.len());
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
    fn route_daemon_message(&mut self, msg: &Value) {
        let ds = match self.daemon_state.as_mut() {
            Some(ds) => ds,
            None => return, // not in daemon mode
        };

        let msg_type = msg.get("type").and_then(Value::as_str).unwrap_or("");

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

    pub async fn start_replay(
        &mut self,
        cmd: &str,
        args: &[&str],
    ) -> Result<usize, Box<dyn Error>> {
        let socket_dir: std::path::PathBuf;
        {
            let path = &CODETRACER_PATHS.lock()?.tmp_path;
            socket_dir = path
                .join("backend-manager")
                .join(std::process::id().to_string());
        }

        create_dir_all(&socket_dir).await?;


        // reserve place
        self.children.push(None);
        // must be > 0 here!
        let id = self.children.len() - 1;

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

        info!(
            "Starting replay with id {id}. Command: {cmd:?}",
        );

        let mut socket_read;
        let mut socket_write;

        info!("Awaiting connection!");

        match listener.accept().await {
            Ok((socket, _addr)) => (socket_read, socket_write) = tokio::io::split(socket),
            Err(err) => return Err(Box::new(err)),
        }

        info!("Accepted connection!");

        let (child_tx, child_rx) = mpsc::unbounded_channel();
        self.children_receivers.push(Some(child_rx));

        let (parent_tx, mut parent_rx) = mpsc::unbounded_channel::<Value>();
        self.parent_senders.push(Some(parent_tx));

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
                            let replay_id = self.start_replay(command, &cmd_args).await?;
                            self.send_manager_message(json!({
                                "type": "response",
                                "success": true,
                                "command": "ct/start-replay",
                                "body": {
                                    "replayId": replay_id
                                }
                            }));
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
                            self.stop_replay(id as usize).await?;
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
                    _ => {
                        if let Some(Value::Object(obj_args)) = args
                            && let Some(Value::Number(id)) = obj_args.get("replay-id")
                            && let Some(id) = id.as_u64()
                        {
                            return self.message(id as usize, message).await;
                        }
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
