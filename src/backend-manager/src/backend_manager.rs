use std::{env, error::Error, fmt::Debug, sync::Arc, time::Duration};

use clap::command;
use serde_json::Value;
use tokio::{
    fs::{create_dir_all, remove_file},
    io::{AsyncReadExt, AsyncWriteExt},
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
};

#[derive(Debug)]
pub struct BackendManager {
    children: Vec<Option<Child>>,
    children_receivers: Vec<Option<UnboundedReceiver<Value>>>,
    parent_senders: Vec<Option<UnboundedSender<Value>>>,
    selected: usize,
}

// TODO: cleanup on exit
// TODO: Handle signals
impl BackendManager {
    pub async fn new() -> Result<Arc<Mutex<Self>>, Box<dyn Error>> {
        let res = Arc::new(Mutex::new(Self {
            children: vec![],
            children_receivers: vec![],
            parent_senders: vec![],
            selected: 0,
        }));

        let res1 = res.clone();
        let res2 = res.clone();

        let mut socket_path = env::temp_dir(); // TODO: discuss what is the best place for the socket. Maybe /run?
        socket_path.push("codetracer");
        socket_path.push("backend-manager");

        create_dir_all(&socket_path).await?;

        socket_path.push(std::process::id().to_string() + ".sock");
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

        tokio::spawn(async move {
            loop {
                sleep(Duration::from_millis(10)).await;

                let mut res = res2.lock().await;
                for rx in &mut res.children_receivers {
                    if let Some(rx) = rx {
                        if !rx.is_empty() {
                            if let Some(message) = rx.recv().await {
                                let write_res =
                                    socket_write.write_all(&DapParser::to_bytes(&message)).await;

                                match write_res {
                                    Ok(()) => {}
                                    Err(err) => {
                                        error!("Can't write to frontend socket! Error: {}", err);
                                    }
                                }
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
                    Ok(mut cnt) => {
                        loop {
                            let val = match parser.parse_bytes(&buff[..cnt]) {
                                Some(Ok(val)) => Some(val),

                                Some(Err(err)) => {
                                    // TODO: log error
                                    None
                                }

                                None => None,
                            };

                            if let Some(x) = val {
                                let mut res = res1.lock().await;
                                match res.parse_message(x).await {
                                    Ok(()) => {}
                                    Err(err) => {
                                        // TODO: log error
                                    }
                                }
                                cnt = 0;
                                continue; // Having goto would be nice here...
                            }
                            break;
                        }
                    }
                    Err(err) => {
                        // TODO: log error
                    }
                }
            }
        });

        Ok(res)
    }

    fn check_id(&self, id: usize) -> Result<(), Box<dyn Error>> {
        if id >= self.children.len() || self.children[id].is_none() {
            return Err(Box::new(InvalidID(id)));
        }

        Ok(())
    }

    pub async fn start_replay(&mut self, cmd: &str, args: &[&str]) -> Result<usize, Box<dyn Error>> {
        let mut socket_path = env::temp_dir(); // TODO: discuss what is the best place for the socket. Maybe /run?
        socket_path.push("codetracer");
        socket_path.push("backend-manager");
        socket_path.push(std::process::id().to_string());

        create_dir_all(&socket_path).await?;

        socket_path.push(self.children.len().to_string() + ".sock");

        let mut cmd = Command::new(cmd);
        cmd.args(args);

        match socket_path.to_str() {
            Some(p) => {
                cmd.arg(p);
            }
            None => return Err(Box::new(SocketPathError)),
        }

        info!(
            "Starting replay with id {}. Command: {:?}",
            self.children.len(),
            cmd
        );

        let child = cmd.spawn();
        let child = match child {
            Ok(c) => c,
            Err(err) => {
                error!("Can't start replay: {}", err);
                return Err(Box::new(err));
            }
        };
        sleep(Duration::from_millis(10)).await;

        self.children.push(Some(child));

        let (mut socket_read, mut socket_write) =
            tokio::io::split(UnixStream::connect(socket_path).await?);

        let (child_tx, child_rx) = mpsc::unbounded_channel();
        self.children_receivers.push(Some(child_rx));

        let (parent_tx, mut parent_rx) = mpsc::unbounded_channel::<Value>();
        self.parent_senders.push(Some(parent_tx));

        tokio::spawn(async move {
            while let Some(message) = parent_rx.recv().await {
                let write_res = socket_write.write_all(&DapParser::to_bytes(&message)).await;
                match write_res {
                    Ok(()) => {}
                    Err(err) => {
                        error!("Can't send message to replay socket! Error: {}", err);
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
                        let val = match parser.parse_bytes(&buff[..cnt]) {
                            Some(Ok(val)) => Some(val),

                            Some(Err(err)) => {
                                warn!("Recieved malformed DAP message! Error: {}", err);
                                None
                            }

                            None => None,
                        };
                        if let Some(x) = val {
                            match child_tx.send(x) {
                                Ok(()) => {}
                                Err(err) => {
                                    error!("Can't send to child channel! Error: {}", err);
                                }
                            };
                        }
                    }
                    Err(err) => {
                        error!("Can't read from replay socket! Error: {}", err);
                    }
                }
            }
        });

        Ok(self.children.len() - 1)
    }

    pub async fn stop_replay(&mut self, id: usize) -> Result<(), Box<dyn Error>> {
        self.check_id(id)?;

        // SAFETY: check_id ensures this is safe
        let child = unsafe { self.children[id].as_mut().unwrap_unchecked() };
        _ = child.kill().await?;

        self.children[id] = None;

        // SAFETY: check_id ensures this is safe
        let child_receiver = unsafe { self.children_receivers[id].as_mut().unwrap_unchecked() };
        child_receiver.close();

        self.children_receivers[id] = None;

        self.parent_senders[id] = None;

        Ok(())
    }

    pub fn select_replay(&mut self, id: usize) -> Result<(), Box<dyn Error>> {
        self.check_id(id)?;

        self.selected = id;

        Ok(())
    }

    async fn parse_message(&mut self, message: Value) -> Result<(), Box<dyn Error>> {
        if !message.is_object() {
            // Not a DAP message. Forwarding...
            return self.message_selected(message).await;
        }

        // SAFETY: The if above ensures that message is object
        let msg = unsafe { message.as_object().unwrap_unchecked().clone() };

        // SAFETY: The statement before the OR ensures safety
        if !msg.contains_key("type") || !unsafe { msg.get("type").unwrap_unchecked().is_string() } {
            // Not a DAP message. Forwarding...
            return self.message_selected(message).await;
        }

        // SAFETY: The if above ensures that message is type exists and is string
        let msg_type = unsafe {
            msg.get("type")
                .unwrap_unchecked()
                .as_str()
                .unwrap_unchecked()
        };

        match msg_type {
            "request" => {
                // SAFETY: The statement before the OR ensures safety
                if !msg.contains_key("command")
                    || !unsafe { msg.get("command").unwrap_unchecked().is_string() }
                {
                    // Malformed DAP request. Forwarding...
                    return self.message_selected(message).await;
                }

                let req_type = unsafe {
                    msg.get("command")
                        .unwrap_unchecked()
                        .as_str()
                        .unwrap_unchecked()
                };

                let args = msg.get("arguments");

                match req_type {
                    "ct/start-replay" => {
                        if args.is_none() {
                            // TODO: return error
                        }

                        // SAFETY: The if above ensures safety
                        let args = unsafe { args.unwrap_unchecked() };

                        if !args.is_array() {
                            // TODO: return error
                        }

                        // SAFETY: The if above ensures safety
                        let args = unsafe { args.as_array().unwrap_unchecked() };

                        if args.is_empty() {
                            // TODO: return error
                        }

                        // TODO: return error
                        let command = unsafe { args.first().unwrap_unchecked() };

                        if !command.is_string() {
                            // TODO: return error
                        }

                        let command = unsafe { command.as_str().unwrap_unchecked() };

                        let args = &args[1..];

                        let mut cmd_args = vec![];

                        for arg in args {
                            if !arg.is_string() {
                                // TODO: return error
                            }

                            // SAFETY: The if above ensures safety
                            let arg = unsafe { arg.as_str().unwrap_unchecked() };
                            cmd_args.push(arg);
                        }

                        self.start_replay(command, &cmd_args).await;
                        // TODO: send response
                        return Ok(());
                    }

                    "ct/stop-replay" => {
                        if args.is_none() {
                            // TODO: return error
                        }
                        // SAFETY: The if above ensures safety
                        let args = unsafe { args.unwrap_unchecked() };

                        if !args.is_u64() {
                            // TODO: return error
                        }

                        // SAFETY: The if above ensures safety
                        let arg = unsafe { args.as_u64().unwrap_unchecked() };

                        return self.stop_replay(arg as usize).await;
                    }

                    "ct/select-replay" => {
                        if args.is_none() {
                            // TODO: return error
                        }
                        // SAFETY: The if above ensures safety
                        let args = unsafe { args.unwrap_unchecked() };

                        if !args.is_u64() {
                            // TODO: return error
                        }

                        // SAFETY: The if above ensures safety
                        let arg = unsafe { args.as_u64().unwrap_unchecked() };

                        return self.select_replay(arg as usize);
                    }

                    _ => {
                        if args.is_none() {
                            // No request arguments. Forwarding...
                            return self.message_selected(message).await;
                        }

                        // SAFETY: The if above ensures that args is not None
                        let args = unsafe { args.unwrap_unchecked() };

                        if !args.is_object() {
                            // Irrelevant args. Forwarding...
                            return self.message_selected(message).await;
                        }

                        // SAFETY: The if above ensures that args is an object
                        let args = unsafe { args.as_object().unwrap_unchecked() };

                        if !args.contains_key("replay-id") {
                            // Not a request to specific backend. Forwarding...
                            return self.message_selected(message).await;
                        }

                        // SAFETY: The if above ensures that replay-id exists
                        let replay_id = unsafe { args.get("replay-id").unwrap_unchecked() };

                        if !replay_id.is_u64() {
                            // Expected integer ID. IDK what this is. Forwarding...
                            return self.message_selected(message).await;
                        }

                        // SAFETY: The if above ensures that args is u64
                        let replay_id = unsafe { replay_id.as_u64().unwrap_unchecked() };

                        return self.message(replay_id as usize, message).await;
                    }
                }
            }

            "event" => {
                // TODO: think of any scenarios, where we will do stuff here. Forward for now.
                return self.message_selected(message).await;
            }

            "response" => {
                // TODO: think of any scenarios, where we will do stuff here. Forward for now.
                return self.message_selected(message).await;
            }

            _ => {
                // Unrecognized DAP message type. Forwarding...
                return self.message_selected(message).await;
            }
        }
    }

    pub async fn message(&self, id: usize, message: Value) -> Result<(), Box<dyn Error>> {
        self.check_id(id)?;

        // SAFETY: check_id ensures this is safe
        let parent_sender = unsafe { self.parent_senders[id].as_ref().unwrap_unchecked() };
        parent_sender.send(message)?;

        Ok(())
    }

    pub async fn message_selected(&self, message: Value) -> Result<(), Box<dyn Error>> {
        self.message(self.selected, message).await
    }
}
