use std::{env, error::Error, fmt::Debug, sync::Arc, thread::sleep, time::Duration};

use serde_json::Value;
use tokio::{
    fs::{create_dir_all, remove_file},
    io::{AsyncReadExt, AsyncWriteExt},
    net::{UnixListener, UnixStream},
    process::{Child, Command},
    sync::{
        Mutex,
        mpsc::{self, Receiver, Sender, UnboundedReceiver, UnboundedSender},
    },
};

use crate::{
    dap_parser::DapParser,
    errors::{InvalidID, SocketPathError},
};

#[derive(Debug)]
pub struct BackendManager {
    children: Vec<Child>,
    children_receivers: Vec<UnboundedReceiver<Value>>,
    parent_senders: Vec<UnboundedSender<Value>>,
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

        create_dir_all(&socket_path).await?;

        socket_path.push(std::process::id().to_string() + ".sock");
        _ = remove_file(&socket_path).await;

        let mut socket_read;
        let mut socket_write;

        let listener = UnixListener::bind(socket_path)?;
        match listener.accept().await {
            Ok((socket, _addr)) => (socket_read, socket_write) = tokio::io::split(socket),
            Err(err) => {
                return Err(Box::new(err))
            }
        }

        tokio::spawn(async move {
            loop {
                let mut res = res2.lock().await;
                for rx in &mut res.children_receivers {
                    if !rx.is_empty() {
                        if let Some(message) = rx.recv().await {
                            socket_write
                                .write_all(&DapParser::to_bytes(message))
                                .await
                                .unwrap(); // TODO: handle error
                        }
                    }
                }

                sleep(Duration::from_millis(10));
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
                                // TODO: log error
                                None
                            }

                            None => None,
                        };
                        if let Some(x) = val {
                            let res = res1.lock().await;
                            res.message_selected(x).await.unwrap(); // TODO: handle error
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
        if id < self.children.len() {
            return Err(Box::new(InvalidID(id)));
        }

        Ok(())
    }

    pub async fn spawn(&mut self) -> Result<usize, Box<dyn Error>> {
        let mut socket_path = env::temp_dir(); // TODO: discuss what is the best place for the socket. Maybe /run?
        socket_path.push("codetracer");
        socket_path.push(std::process::id().to_string());

        create_dir_all(&socket_path).await?;

        socket_path.push(self.children.len().to_string() + ".sock");

        let mut cmd = Command::new("db-backend");
        match socket_path.to_str() {
            Some(p) => {
                cmd.arg(p);
            }
            None => return Err(Box::new(SocketPathError)),
        }

        let child = cmd.spawn()?;
        sleep(Duration::from_millis(10));

        self.children.push(child);

        let (mut socket_read, mut socket_write) =
            tokio::io::split(UnixStream::connect(socket_path).await?);

        let (child_tx, child_rx) = mpsc::unbounded_channel();
        self.children_receivers.push(child_rx);

        let (parent_tx, mut parent_rx) = mpsc::unbounded_channel::<Value>();
        self.parent_senders.push(parent_tx);

        tokio::spawn(async move {
            while let Some(message) = parent_rx.recv().await {
                socket_write
                    .write_all(&DapParser::to_bytes(message))
                    .await
                    .unwrap(); // TODO: handle error
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
                                // TODO: log error
                                None
                            }

                            None => None,
                        };
                        if let Some(x) = val {
                            child_tx.send(x); // TODO: handle error appropriately
                        }
                    }
                    Err(err) => {
                        // TODO: log error
                    }
                }
            }
        });

        Ok(self.children.len() - 1)
    }

    pub fn select(&mut self, id: usize) -> Result<(), Box<dyn Error>> {
        self.check_id(id)?;

        self.selected = id;

        Ok(())
    }

    pub async fn message(&self, id: usize, message: Value) -> Result<(), Box<dyn Error>> {
        self.check_id(id)?;

        self.parent_senders[id].send(message);

        Ok(())
    }

    pub async fn message_selected(&self, message: Value) -> Result<(), Box<dyn Error>> {
        self.message(self.selected, message).await
    }
}
