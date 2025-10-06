use std::error::Error;
use std::fs::create_dir_all;
use std::io::Write;

use std::os::unix::net::UnixStream;

use std::path::PathBuf;

use std::str;

use crate::paths::CODETRACER_PATHS;
use serde::de::DeserializeOwned;
use serde::Serialize;
// use crate::event::Event;
use crate::task::{gen_task_id, to_task_kind_text, EventId, TaskId, TaskKind};

// hopefully impossible for normal PID-s, as they start
// from 1 for init?
pub const NO_CALLER_PROCESS_PID: usize = 0;

#[derive(Debug, Default)]
pub struct Core {
    pub socket: Option<UnixStream>,
    pub caller_process_pid: usize,
}

impl Core {
    pub fn send<T: Serialize>(&self, task_kind: TaskKind, value: T) -> Result<(), Box<dyn Error>> {
        let task_id = gen_task_id(task_kind);
        self.write_arg(&task_id, value)?;
        self.send_task_message(task_kind, task_id)?;
        Ok(())
    }

    pub fn write_arg<T: Serialize>(&self, task_id: &TaskId, value: T) -> Result<(), Box<dyn Error>> {
        self.write_raw_arg(task_id, &self.serialize(value)?)
    }

    pub fn write_raw_arg(&self, task_id: &TaskId, raw: &str) -> Result<(), Box<dyn Error>> {
        let arg_path = self.ensure_arg_path_for(task_id)?;
        // println!("arg_path {:?}", arg_path);
        std::fs::write(arg_path, raw)?;
        Ok(())
    }

    pub fn read_arg<T: DeserializeOwned>(&self, task_id: &TaskId) -> Result<T, Box<dyn Error>> {
        let raw = self.read_raw_arg(task_id)?;
        // info!("---- we are getting {} - T({:?})", raw, std::any::type_name::<T>());
        let res: T = serde_json::from_str(&raw)?;
        Ok(res)
    }

    pub fn read_raw_arg(&self, task_id: &TaskId) -> Result<String, Box<dyn Error>> {
        let arg_path = self.ensure_arg_path_for(task_id)?;
        let res = str::from_utf8(&std::fs::read(arg_path)?)?.to_string();
        Ok(res)
    }

    pub fn run_dir(&self) -> Result<PathBuf, Box<dyn Error>> {
        let path = CODETRACER_PATHS.lock()?;
        Ok(path.tmp_path.join(format!("run-{}", self.caller_process_pid)))
    }

    pub fn ensure_arg_path_for(&self, task_id: &TaskId) -> Result<PathBuf, Box<dyn Error>> {
        let run_dir = self.run_dir()?;
        let arg_dir = run_dir.join("args");
        create_dir_all(&arg_dir)?;
        let raw_task_id = task_id.as_string();
        Ok(arg_dir.join(format!("{raw_task_id}.json")))
    }

    pub fn ensure_result_path_for(&self, task_id: TaskId) -> Result<PathBuf, Box<dyn Error>> {
        let run_dir = self.run_dir()?;
        let results_dir = run_dir.join("results");
        create_dir_all(&results_dir)?;
        let raw_task_id = task_id.as_string();
        Ok(results_dir.join(format!("{raw_task_id}.json")))
    }

    pub fn client_results_path(&self) -> Result<PathBuf, Box<dyn Error>> {
        let run_dir = self.run_dir()?;
        Ok(run_dir.join("client_results.txt"))
    }

    pub fn ensure_event_path_for(&self, event_id: EventId) -> Result<PathBuf, Box<dyn Error>> {
        let run_dir = self.run_dir()?;
        let events_dir = run_dir.join("events");
        create_dir_all(&events_dir)?;
        let raw_event_id = event_id.as_string();
        Ok(events_dir.join(format!("{raw_event_id}.json")))
    }

    fn serialize<T: Serialize>(&self, value: T) -> Result<String, Box<dyn Error>> {
        // TODO serde
        let raw = serde_json::to_string(&value)?;
        Ok(raw)
    }

    // setup should be called before send_loop !
    // eventually we can check explicitly or initialize
    // Sender with setup to make socket not Option
    #[allow(clippy::unwrap_used)]
    fn send_task_message(&self, task_kind: TaskKind, task_id: TaskId) -> Result<(), Box<dyn Error>> {
        let raw = format!("{} {}\n", to_task_kind_text(task_kind), task_id.as_string());
        // info!("send socket {raw}");
        self.socket.as_ref().unwrap().write_all(raw.as_bytes())?;
        Ok(())
    }
}
