use std::env;
use std::error::Error;
use std::fs::create_dir_all;
use std::io::Write;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
// use std::process::ChildStdin;
use std::str;
use std::time;

use crate::event::Event;
use crate::task::{gen_task_id, to_event_kind, to_task_kind_text, EventId, TaskId, TaskKind};
use serde::Serialize;
use tokio;
use tokio::sync::mpsc;

pub const CODETRACER_TMP_PATH: &str = "/tmp/codetracer";

#[derive(Debug, Default)]
pub struct Core {
    //   pub stdin_file: Option<std::fs::File>,
    pub socket: Option<UnixStream>,
    pub caller_process_pid: u32,
    //   pub last_line_length: usize
}

impl Core {
    pub fn send<T: Serialize>(&self, task_kind: TaskKind, value: T) -> Result<(), Box<dyn Error>> {
        let task_id = gen_task_id(task_kind);
        self.write_arg(task_id.clone(), value)?;
        self.send_task_message(task_kind, task_id)?;
        Ok(())
    }

    fn write_arg<T: Serialize>(&self, task_id: TaskId, value: T) -> Result<(), Box<dyn Error>> {
        self.write_raw_arg(task_id, &self.serialize(value)?)
    }

    fn write_raw_arg(&self, task_id: TaskId, raw: &str) -> Result<(), Box<dyn Error>> {
        let arg_path = self.ensure_arg_path_for(task_id)?;
        // println!("arg_path {:?}", arg_path);
        std::fs::write(arg_path, raw)?;
        Ok(())
    }

    fn run_dir(&self) -> PathBuf {
        PathBuf::from(CODETRACER_TMP_PATH).join(format!("run-{}", self.caller_process_pid))
    }

    fn ensure_arg_path_for(&self, task_id: TaskId) -> Result<PathBuf, Box<dyn Error>> {
        let run_dir = self.run_dir();
        let arg_dir = run_dir.join("args");
        create_dir_all(&arg_dir)?;
        let raw_task_id = task_id.as_string();
        Ok(arg_dir.join(format!("{raw_task_id}.json")))
    }

    pub fn client_results_path(&self) -> PathBuf {
        let run_dir = self.run_dir();
        run_dir.join("client_results.txt")
    }

    pub fn event_path(&self, event_id: EventId) -> PathBuf {
        let run_dir = self.run_dir();
        let events_dir = run_dir.join("events");
        let raw_event_id = event_id.as_string();
        events_dir.join(format!("{raw_event_id}.json"))
    }

    fn serialize<T: Serialize>(&self, value: T) -> Result<String, Box<dyn Error>> {
        // TODO serde
        let raw = serde_json::to_string(&value)?;
        Ok(raw)
    }

    fn send_task_message(
        &self,
        task_kind: TaskKind,
        task_id: TaskId,
    ) -> Result<(), Box<dyn Error>> {
        let raw = format!("{} {}\n", to_task_kind_text(task_kind), task_id.as_string());
        eprintln!("send socket {raw}");
        self.socket.as_ref().unwrap().write_all(raw.as_bytes())?;
        Ok(())
    }
}

fn read_core_responses() -> Option<String> {
    // }, Box<dyn Error>> {
    let core = Core {
        socket: None, // not important here
        caller_process_pid: caller_process_pid(),
    };
    let path = core.client_results_path();
    let raw_bytes_res = std::fs::read(path);
    if let Ok(raw_bytes) = raw_bytes_res {
        let raw_res = str::from_utf8(&raw_bytes);
        if let Ok(raw) = raw_res {
            //   eprintln!("core responses {raw}");
            return Some(raw.to_string());
        }
    }
    None
}

fn load_response(line: &str) -> Event {
    let tokens = line.split(' ').collect::<Vec<&str>>();
    if tokens.len() != 3 {
        return Event::Error {
            message: format!("can't parse core response: {line}"),
        };
    }
    if tokens[0] == "return" {
        eprintln!("ignoring: {line}");
        Event::Error {
            message: "ignoring result".to_string(),
        }
    } else {
        // event
        // eprintln!("processing: {line}");
        let raw_event_kind = tokens[1];
        let raw_event_id = tokens[2];
        if let Some(event_kind) = to_event_kind(raw_event_kind) {
            let event_id = EventId::new(raw_event_id);
            let core = Core {
                socket: None, // not important here
                caller_process_pid: caller_process_pid(),
            };
            let event_path = core.event_path(event_id.clone());
            let res = std::fs::read(event_path);
            match res {
                Ok(raw) => Event::CoreEvent {
                    event_kind,
                    event_id,
                    raw: str::from_utf8(&raw).expect("valid text").to_string(),
                },
                Err(e) => Event::Error {
                    message: format!("{e:?}"),
                },
            }
        } else {
            Event::Error {
                message: format!("no event kind {raw_event_kind}"),
            }
        }
    }
}

pub fn track_responses(tx: mpsc::Sender<Event>) {
    tokio::spawn(async move {
        let mut next_line_index = 0usize;
        loop {
            eprintln!("read core responses");
            let maybe_core_raw = read_core_responses();
            if let Some(core_raw) = maybe_core_raw {
                let lines = core_raw.trim().split('\n').collect::<Vec<&str>>();
                for i in next_line_index..lines.len() {
                    let line = lines[i];
                    if line.len() > 0 {
                        next_line_index = i + 1;
                        // eprintln!("load [{line}]");
                        let event = load_response(&line);
                        // eprintln!("send {event:?}");
                        tx.send(event).await.unwrap();
                    }
                }
                // last_line_length = lines.len();
                // eprintln!("next_line_index {next_line_index}");
            } else {
                eprintln!("error {maybe_core_raw:?}");
            }
            // tx.send(
            //     Event::CoreEvent {
            //     event_kind: EventKind::CompleteMove,
            //     event_id: EventId::new("complete-move-0"),
            //     raw: "".to_string()
            // }).await.unwrap();
            tokio::time::sleep(time::Duration::from_millis(1000)).await;
        }
    });
}

// before: std::process::id();
pub fn caller_process_pid() -> u32 {
    let res: Result<u32, _> = env::var("CODETRACER_CALLER_PROCESS_PID")
        .unwrap_or("1".to_string())
        .parse();
    res.unwrap_or(1)
}
