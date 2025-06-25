use log::{error, info};
use std::error::Error;
use std::fs;
use std::io::Write;
use std::io::{BufRead, BufReader};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};

use crate::core::{Core, NO_CALLER_PROCESS_PID};
use crate::handler::Handler;
use crate::paths::CODETRACER_PATHS;
use crate::sender::Sender;
use crate::task::{to_task_kind, Task, TaskId, TaskKind};

pub struct Receiver {
    receiving_socket: Option<UnixStream>,
    core: Core,
}

// acting as a dispatcher as well for now
#[allow(clippy::new_without_default)]
impl Receiver {
    pub fn new() -> Receiver {
        Receiver {
            receiving_socket: None,
            core: Core {
                socket: None,
                caller_process_pid: NO_CALLER_PROCESS_PID,
            },
        }
    }

    pub fn setup(&mut self, caller_process_pid: usize) -> Result<(), Box<dyn Error>> {
        // TODO:
        //   init or let index init client->core socket
        //   and use it, storing in object
        //   in loop, read from it and on read
        //   try to parse and call relevant
        //   handler methods, then to send results/events
        //   to sender(or pass sender to the methods?)
        //var socket = newSocket(domain=Domain.AF_UNIX, sockType=SockType.SOCK_STREAM, protocol=Protocol.IPPROTO_IP)
        //socket.setSockOpt(OptReuseAddr, true)
        let socket_path: PathBuf;
        {
            let tmp = CODETRACER_PATHS.lock()?;
            let path = tmp.socket_path.display();
            socket_path = PathBuf::from(format!("{path}_{caller_process_pid}"));
        }
        self.setup_socket(&socket_path, caller_process_pid, true)
    }

    pub fn setup_for_virtualization_layers(
        &mut self,
        socket_path: &Path,
        caller_process_pid: usize,
    ) -> Result<(), Box<dyn Error>> {
        self.setup_socket(socket_path, caller_process_pid, false)
    }

    fn setup_socket(
        &mut self,
        socket_path: &Path,
        caller_process_pid: usize,
        create: bool,
    ) -> Result<(), Box<dyn Error>> {
        self.core.caller_process_pid = caller_process_pid;
        if create {
            let _ = std::fs::remove_file(socket_path);
            let listener = UnixListener::bind(socket_path)?;
            match listener.accept() {
                Ok((socket, _addr)) => {
                    info!("backend: socket {:?}", socket);
                    self.receiving_socket = Some(socket);
                    Ok(())
                }
                Err(e) => {
                    error!("backend: error {:?}", e);
                    Err(format!("no socket {:?}", e).into())
                }
            }
        } else {
            let socket = UnixStream::connect(socket_path)?;
            self.receiving_socket = Some(socket);
            Ok(())
        }
    }

    // _tx: mpsc::Sender<Response>?
    #[allow(clippy::expect_used)]
    pub fn receive_loop(&mut self, handler: &mut Handler) -> Result<(), Box<dyn Error>> {
        let stream = self.receiving_socket.as_ref().expect("valid socket");
        let mut sending_socket = stream.try_clone().expect("can clone");
        // based, copied and adapted from
        // http://kmdouglass.github.io/posts/a-simple-unix-socket-listener-in-rust/
        let stream = BufReader::new(stream);
        info!("waiting for input");
        for line_res in stream.lines() {
            info!("line_res {line_res:?}");

            match line_res {
                Ok(line) => {
                    info!("backend: raw line {line}");

                    let message_res = self.parse_message(&line);
                    match message_res {
                        Ok(task) => {
                            let res = self.handle_task(handler, task);
                            if let Err(handle_error) = res {
                                error!("backend: handle error: {:?}", handle_error);
                            } else if handler.indirect_send {
                                let responses = handler.get_responses_for_sending_and_clear();
                                let mut sender = Sender::new();
                                let _ = sender.setup(self.core.caller_process_pid, false);
                                for response in responses {
                                    let (message, path, payload) = sender.prepare_message(response);
                                    let write_res = fs::write(path.clone(), payload);
                                    info!("wrote {:?}", path);
                                    match write_res {
                                        Ok(_) => {
                                            let send_res = sending_socket.write_all(message.as_bytes());
                                            if let Err(send_error) = send_res {
                                                error!("sender couldn't send message: {:?}", send_error);
                                            }
                                            info!("sent to client {:?}", message);
                                        }
                                        Err(e) => {
                                            error!("sender couldn't save to {}: {}", path.display(), e);
                                        }
                                    }
                                }
                            }
                        }
                        Err(e) => {
                            error!("backend: error: {:?}", e);
                        }
                    }
                }
                Err(e) => {
                    error!("backend: receiver: line_res: {:?}", e);
                }
            }

            // TODO: parse to Message
            // call handle_message
            // TODO: in future, maybe run receiver in separate thread
            // and send message to handler thread
            // for now easier like that tho
        }
        Ok(())
    }

    fn parse_message(&self, raw: &str) -> Result<Task, Box<dyn Error>> {
        let tokens = raw.split(' ').collect::<Vec<&str>>();
        if tokens.len() != 2 {
            return Err("expected 2 tokens in received message".into());
        }
        let raw_task_kind = tokens[0];
        let raw_task_id = tokens[1];
        if let Some(task_kind) = to_task_kind(raw_task_kind) {
            let task_id = TaskId::new(raw_task_id);
            Ok(Task::new(task_kind, task_id))
        } else {
            Err(format!("task kind {raw_task_kind} not implemented or supported").into())
        }
    }

    pub fn handle_task(&self, handler: &mut Handler, task: Task) -> Result<(), Box<dyn Error>> {
        // we can make a proxy like DispatcherSender -> Sender in sender thread
        // for now just using handler helper methods which use handler.tx
        info!("handle_task {:?}", task);
        match task.kind {
            // TODO: configure arg if needed
            TaskKind::Configure => handler.configure(self.core.read_arg(&task.id)?, task),
            TaskKind::Start => handler.start(task),
            TaskKind::RunToEntry => handler.run_to_entry(task),
            // TaskKind::LoadLocals => handler.load_locals(task),
            TaskKind::LoadCallstack => handler.load_callstack(task),
            TaskKind::CollapseCalls => handler.collapse_calls(self.core.read_arg(&task.id)?, task),
            TaskKind::ExpandCalls => handler.expand_calls(self.core.read_arg(&task.id)?, task),
            TaskKind::LoadCallArgs => handler.load_call_args(self.core.read_arg(&task.id)?, task),
            TaskKind::LoadFlow => handler.load_flow(self.core.read_arg(&task.id)?, task),
            // superseded by dap_server
            // TaskKind::Step => handler.step(self.core.read_arg(&task.id)?, task),
            TaskKind::EventLoad => handler.event_load(task),
            TaskKind::EventJump => handler.event_jump(self.core.read_arg(&task.id)?, task),
            TaskKind::CalltraceJump => handler.calltrace_jump(self.core.read_arg(&task.id)?, task),
            TaskKind::SourceLineJump => handler.source_line_jump(self.core.read_arg(&task.id)?, task),
            TaskKind::SourceCallJump => handler.source_call_jump(self.core.read_arg(&task.id)?, task),
            TaskKind::AddBreak => handler.add_breakpoint(self.core.read_arg(&task.id)?, task),
            TaskKind::DeleteBreak => handler.delete_breakpoint(self.core.read_arg(&task.id)?, task),
            TaskKind::Disable => handler.toggle_breakpoint(self.core.read_arg(&task.id)?, task),
            TaskKind::Enable => handler.toggle_breakpoint(self.core.read_arg(&task.id)?, task),
            TaskKind::RunTracepoints => handler.run_tracepoints(self.core.read_arg(&task.id)?, task),
            TaskKind::TraceJump => handler.trace_jump(self.core.read_arg(&task.id)?, task),
            TaskKind::HistoryJump => handler.history_jump(self.core.read_arg(&task.id)?, task),
            TaskKind::LoadHistory => handler.load_history(self.core.read_arg(&task.id)?, task),
            TaskKind::UpdateTable => handler.update_table(self.core.read_arg(&task.id)?, task),
            TaskKind::TracepointDelete => handler.tracepoint_delete(self.core.read_arg(&task.id)?, task),
            TaskKind::TracepointToggle => handler.tracepoint_toggle(self.core.read_arg(&task.id)?, task),
            TaskKind::CalltraceSearch => handler.calltrace_search(self.core.read_arg(&task.id)?, task),
            TaskKind::SearchProgram => handler.search_program(self.core.read_arg(&task.id)?, task),
            TaskKind::LoadStepLines => handler.load_step_lines(self.core.read_arg(&task.id)?, task),
            TaskKind::LocalStepJump => handler.local_step_jump(self.core.read_arg(&task.id)?, task),
            TaskKind::RegisterEvents => handler.register_events(self.core.read_arg(&task.id)?, task),
            TaskKind::RegisterTracepointLogs => handler.register_tracepoint_logs(self.core.read_arg(&task.id)?, task),
            TaskKind::SetupTraceSession => handler.setup_trace_session(self.core.read_arg(&task.id)?, task),
            TaskKind::LoadAsmFunction => handler.load_asm_function(self.core.read_arg(&task.id)?, task),
            TaskKind::LoadTerminal => handler.load_terminal(task),
            _ => {
                unimplemented!()
            }
        }
    }
}
