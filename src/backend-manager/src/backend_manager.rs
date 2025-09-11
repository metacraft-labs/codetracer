use std::{error::Error, fmt::Debug, sync::Arc, time::Duration};

use serde_json::Value;
use tokio::{
    fs::{create_dir_all, remove_file},
    io::{AsyncReadExt, AsyncWriteExt},
    net::UnixListener,
    process::{Child, Command},
    sync::{
        Mutex,
        mpsc::{self, UnboundedReceiver, UnboundedSender},
    },
    time::sleep,
};

use crate::{
    dap_parser::DapParser,
    paths::CODETRACER_PATHS,
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

        tokio::spawn(async move {
            loop {
                sleep(Duration::from_millis(10)).await;

                let mut res = res2.lock().await;
                for rx in res.children_receivers.iter_mut().flatten() {
                    if !rx.is_empty() {
                        if let Some(message) = rx.recv().await {
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
                                    error!("Invalid DAP message received. Error: {err}");

                                    None
                                }

                                None => None,
                            };

                            if let Some(x) = val {
                                let mut res = res1.lock().await;
                                match res.dispatch_message(x).await {
                                    Ok(()) => {}
                                    Err(err) => {
                                        error!("Can't handle DAP message. Error: {err}");
                                    }
                                }
                                cnt = 0;
                                continue; // Having goto would be nice here...
                            }
                            break;
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
            socket_dir = path.join("backend-manager").join(std::process::id().to_string());
        }

        create_dir_all(&socket_dir).await?;

        let socket_path = socket_dir.join(self.children.len().to_string() + ".sock");
        _ = remove_file(&socket_path).await;

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

        let listener = UnixListener::bind(socket_path)?;

        let child = cmd.spawn();
        let child = match child {
            Ok(c) => c,
            Err(err) => {
                error!("Can't start replay: {err}");
                return Err(Box::new(err));
            }
        };

        self.children.push(Some(child));

        let mut socket_read;
        let mut socket_write;

        debug!("Awaiting connection!");

        match listener.accept().await {
            Ok((socket, _addr)) => (socket_read, socket_write) = tokio::io::split(socket),
            Err(err) => return Err(Box::new(err)),
        }

        debug!("Accepted connection!");

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
                        let val = match parser.parse_bytes(&buff[..cnt]) {
                            Some(Ok(val)) => Some(val),

                            Some(Err(err)) => {
                                warn!("Recieved malformed DAP message! Error: {err}");
                                None
                            }

                            None => None,
                        };
                        if let Some(x) = val {
                            match child_tx.send(x) {
                                Ok(()) => {}
                                Err(err) => {
                                    error!("Can't send to child channel! Error: {err}");
                                }
                            };
                        }
                    }
                    Err(err) => {
                        error!("Can't read from replay socket! Error: {err}");
                    }
                }
            }
        });

        Ok(self.children.len() - 1)
    }

    pub async fn stop_replay(&mut self, id: usize) -> Result<(), Box<dyn Error>> {
        self.check_id(id)?;

        if let Some(child_opt) = self.children.get_mut(id) {
            if let Some(child) = child_opt.as_mut() {
                child.kill().await?;
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

        Ok(())
    }

    pub fn select_replay(&mut self, id: usize) -> Result<(), Box<dyn Error>> {
        self.check_id(id)?;

        self.selected = id;

        Ok(())
    }

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

                match req_type {
                    "ct/start-replay" => {
                        if let Some(Value::Array(arr)) = args {
                            if let Some(Value::String(command)) = arr.first() {
                                let mut cmd_args: Vec<&str> = Vec::new();
                                for arg in arr.iter().skip(1) {
                                    if let Some(s) = arg.as_str() {
                                        cmd_args.push(s);
                                    } else {
                                        // TODO: return error
                                        return Ok(());
                                    }
                                }
                                self.start_replay(command, &cmd_args).await?;
                                // TODO: send response
                                return Ok(());
                            }
                        }
                        // TODO: return error
                        Ok(())
                    }
                    "ct/stop-replay" => {
                        if let Some(Value::Number(num)) = args {
                            if let Some(id) = num.as_u64() {
                                self.stop_replay(id as usize).await?;
                                return Ok(());
                            }
                        }
                        // TODO: return error
                        Ok(())
                    }
                    "ct/select-replay" => {
                        if let Some(Value::Number(num)) = args {
                            if let Some(id) = num.as_u64() {
                                self.select_replay(id as usize)?;
                                return Ok(());
                            }
                        }
                        // TODO: return error
                        Ok(())
                    }
                    _ => {
                        if let Some(Value::Object(obj_args)) = args {
                            if let Some(Value::Number(id)) = obj_args.get("replay-id") {
                                if let Some(id) = id.as_u64() {
                                    return self.message(id as usize, message).await;
                                }
                            }
                        }
                        self.message_selected(message).await
                    }
                }
            }
            "event" | "response" => self.message_selected(message).await,
            _ => self.message_selected(message).await,
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
