use crate::dap::{self, DapMessage, Event, ProtocolMessage, Response};
use serde_json::json;
use std::io::BufReader;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::error::Error;

const DAP_SOCKET_PATH: &str = "/tmp/ct_dap_socket";

pub fn socket_path_for(pid: usize) -> PathBuf {
    PathBuf::from(format!("{DAP_SOCKET_PATH}_{}", pid))
}

pub fn run(socket_path: &Path) -> Result<(), Box<dyn Error>> {
    let _ = std::fs::remove_file(socket_path);
    let listener = UnixListener::bind(socket_path)?;
    let (stream, _) = listener.accept()?;
    handle_client(stream)
}

fn handle_client(stream: UnixStream) -> Result<(), Box<dyn Error>> {
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut writer = stream;
    let mut seq = 1i64;
    while let Ok(msg) = dap::from_reader(&mut reader) {
        match msg {
            DapMessage::Request(req) if req.command == "initialize" => {
                let resp = DapMessage::Response(Response {
                    base: ProtocolMessage { seq, type_: "response".to_string() },
                    request_seq: req.base.seq,
                    success: true,
                    command: "initialize".to_string(),
                    message: None,
                    body: json!({}),
                });
                seq += 1;
                dap::write_message(&mut writer, &resp)?;
            }
            DapMessage::Request(req) if req.command == "launch" => {
                let event = DapMessage::Event(Event {
                    base: ProtocolMessage { seq, type_: "event".to_string() },
                    event: "initialized".to_string(),
                    body: json!({}),
                });
                seq += 1;
                dap::write_message(&mut writer, &event)?;
                let resp = DapMessage::Response(Response {
                    base: ProtocolMessage { seq, type_: "response".to_string() },
                    request_seq: req.base.seq,
                    success: true,
                    command: "launch".to_string(),
                    message: None,
                    body: json!({}),
                });
                seq += 1;
                dap::write_message(&mut writer, &resp)?;
            }
            _ => {}
        }
    }
    Ok(())
}
