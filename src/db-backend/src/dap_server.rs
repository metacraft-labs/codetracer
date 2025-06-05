use crate::dap::{self, DapMessage, Event, ProtocolMessage, RequestArguments, Response};
use crate::trace_processor::load_trace_metadata;
use serde_json::json;
use std::error::Error;
use std::io::BufReader;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};

pub const DAP_SOCKET_PATH: &str = "/tmp/ct_dap_socket";

fn run_to_entry(writer: &mut UnixStream, seq: &mut i64) -> Result<(), Box<dyn Error>> {
    // TODO: run trace to program entry once trace processing is integrated
    let event = DapMessage::Event(Event {
        base: ProtocolMessage {
            seq: *seq,
            type_: "event".to_string(),
        },
        event: "stopped".to_string(),
        body: json!({"hitBreakpointIds": []}),
    });
    *seq += 1;
    dap::write_message(writer, &event)?;
    Ok(())
}

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
                    base: ProtocolMessage {
                        seq,
                        type_: "response".to_string(),
                    },
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
                if let RequestArguments::Launch(args) = &req.arguments {
                    if let Some(folder) = &args.trace_folder {
                        let metadata_path = folder.join("trace_metadata.json");
                        match load_trace_metadata(&metadata_path) {
                            Ok(meta) => println!("TRACE METADATA: {:?}", meta),
                            Err(e) => eprintln!("failed to read metadata: {}", e),
                        }
                    }
                    if let Some(pid) = args.pid {
                        println!("PID: {}", pid);
                    }
                }
                run_to_entry(&mut writer, &mut seq)?;
                let resp = DapMessage::Response(Response {
                    base: ProtocolMessage {
                        seq,
                        type_: "response".to_string(),
                    },
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
