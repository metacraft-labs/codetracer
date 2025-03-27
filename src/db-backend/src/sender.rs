use crate::core::{Core, NO_CALLER_PROCESS_PID};
// use crate::receiver::Receiver;
use crate::response::Response;
use crate::task::{to_event_kind_text, to_task_kind_text};
use log::{error, info};
use std::error::Error;
use std::fmt;
use std::fs;
use std::io::Write;

#[cfg (target_os = "windows")]
use uds_windows::{UnixListener, UnixStream};

#[cfg (target_os = "linux")]
use std::os::unix::net::{UnixListener, UnixStream};

use std::path::{Path, PathBuf};
use std::sync::mpsc;

const CT_CLIENT_SOCKET_PATH: &str = "/tmp/ct_client_socket";

pub struct Sender {
    sending_socket: Option<UnixStream>,
    responses: Vec<Response>,
    core: Core,
}

impl fmt::Debug for Sender {
    fn fmt(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
        let sending_socket_text = match self.sending_socket {
            Some(_) => "Some(..)",
            None => "None",
        };
        write!(
            formatter,
            "Sender {{ sending_socket: {}, core: {:?} }}",
            sending_socket_text, self.core
        )
    }
}

#[allow(clippy::new_without_default)]
impl Sender {
    pub fn new() -> Sender {
        Sender {
            sending_socket: None,
            responses: vec![],
            core: Core {
                socket: None,
                caller_process_pid: NO_CALLER_PROCESS_PID,
            },
        }
    }

    pub fn setup(&mut self, caller_process_pid: usize, with_socket: bool) -> Result<(), Box<dyn Error>> {
        self.core = Core {
            socket: None,
            caller_process_pid,
        };

        if with_socket {
            let socket_path = PathBuf::from(format!("{CT_CLIENT_SOCKET_PATH}_{caller_process_pid}"));

            self.setup_socket(&socket_path)
        } else {
            Ok(())
        }
    }

    fn setup_socket(&mut self, socket_path: &Path) -> Result<(), Box<dyn Error>> {
        let _ = std::fs::remove_file(socket_path);
        let listener = UnixListener::bind(socket_path)?;
        match listener.accept() {
            Ok((socket, _addr)) => {
                self.sending_socket = Some(socket);
                Ok(())
            }
            Err(e) => Err(format!("no socket for sender {:?}", e).into()),
        }
    }

    pub fn prepare_response(&mut self, response: Response) {
        self.responses.push(response);
    }

    pub fn clear_responses(&mut self) {
        self.responses = vec![];
    }

    pub fn get_responses(&self) -> Vec<Response> {
        self.responses.clone()
    }

    pub fn setup_for_virtualization_layers(&mut self, caller_process_pid: usize) {
        self.core = Core {
            socket: None,
            caller_process_pid,
        };
        // self.sending_socket = Some(socket);
    }

    #[allow(clippy::expect_used)]
    pub fn send_loop(&mut self, rx: mpsc::Receiver<Response>) -> Result<(), Box<dyn Error>> {
        loop {
            let response = rx.recv()?;
            self.send_response(response)?;
        }
    }

    // pub fn send_response_with_socket(&self, response: Response, socket: &mut UnixStream) -> Result<(), Box<dyn Error>> {
    #[allow(clippy::expect_used)]
    pub fn send_response(&mut self, response: Response) -> Result<(), Box<dyn Error>> {
        // -> return <task-kind> <task-id>
        // or
        // -> event <event-kind> <event-id>
        // also store value always in file
        let (message, path, payload) = self.prepare_message(response);
        let write_res = fs::write(path.clone(), payload);
        match write_res {
            Ok(_) => {
                let socket = self.sending_socket.as_mut().expect("socket available");
                let send_res = socket.write_all(message.as_bytes());
                if let Err(send_error) = send_res {
                    error!("sender couldn't send message: {:?}", send_error);
                }
                info!("sent to client {:?}", message);
            }
            Err(e) => {
                error!("sender couldn't save to {}: {}", path.display(), e);
            }
        }
        Ok(())
    }
    // we assume for now communication helpers work
    // because we're not robust enough yet anyway
    // eventually it might be good to somehow detect
    // more precisely problems here but there will be always
    // limits like hard disk/memory free space, os limits and others
    #[allow(clippy::expect_used)]
    pub fn prepare_message(&self, response: Response) -> (String, PathBuf, String) {
        match response {
            Response::TaskResponse((task, payload)) => (
                format!("return {} {}\n", to_task_kind_text(task.kind), task.id.as_string()),
                self.core.ensure_result_path_for(task.id).expect("valid result path"),
                payload,
            ),
            Response::EventResponse((event_kind, event_id, payload, raw)) => {
                let send_kind = if !raw { "event" } else { "raw-event" };
                (
                    format!(
                        "{} {} {}\n",
                        send_kind,
                        to_event_kind_text(event_kind),
                        event_id.as_string()
                    ),
                    self.core.ensure_event_path_for(event_id).expect("valid event path"),
                    payload,
                )
            }
        }
    }
}
