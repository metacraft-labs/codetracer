use std::error::Error;
use std::io::Write;
use std::io::{BufRead, BufReader};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::Duration;

use log::{info, warn};
use runtime_tracing::{StepId, ValueRecord};

use crate::db::DbRecordEvent;
use crate::expr_loader::ExprLoader;
use crate::paths::ct_rr_worker_socket_path;
use crate::query::CtRRQuery;
use crate::replay::{Events, Replay};
use crate::task::{Action, Location, CtLoadLocalsArguments, Variable};

#[derive(Debug)]
pub struct RRDispatcher {
    pub stable: CtRRWorker,
    pub ct_rr_worker_exe: PathBuf,
    pub rr_trace_folder: PathBuf,
}

#[derive(Debug)]
pub struct CtRRWorker {
    pub name: String,
    pub active: bool,
    pub ct_rr_worker_exe: PathBuf,
    pub rr_trace_folder: PathBuf,
    process: Option<Child>,
    stream: Option<UnixStream>,
}

#[derive(Default)]
pub struct CtRRArgs {
    pub worker_exe: PathBuf,
    pub rr_trace_folder: PathBuf,
}

impl CtRRWorker {
    pub fn new(name: &str, ct_rr_worker_exe: &Path, rr_trace_folder: &Path) -> CtRRWorker {
        CtRRWorker {
            name: name.to_string(),
            active: false,
            ct_rr_worker_exe: PathBuf::from(ct_rr_worker_exe),
            rr_trace_folder: PathBuf::from(rr_trace_folder),
            process: None,
            stream: None,
        }
    }

    pub fn start(&mut self) -> Result<(), Box<dyn Error>> {
        info!(
            "start: {} --name {} replay {}",
            self.ct_rr_worker_exe.display(),
            self.name,
            self.rr_trace_folder.display()
        );
        let ct_worker = Command::new(&self.ct_rr_worker_exe)
            .arg("replay")
            .arg("--name")
            .arg(&self.name)
            .arg(&self.rr_trace_folder)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()?;

        self.process = Some(ct_worker);
        self.setup_worker_sockets()?;
        self.active = true;
        Ok(())
    }

    fn setup_worker_sockets(&mut self) -> Result<(), Box<dyn Error>> {
        // assuming that the ct rr worker creates the sockets!
        // code copied and adapted from `connect_socket_with_backend_and_loop` in ct-rr-worker
        //   which is itself copied/adapted/written from/based on https://emmanuelbosquet.com/2022/whatsaunixsocket/

        let run_id = std::process::id() as usize;

        let socket_path = ct_rr_worker_socket_path("", &self.name, run_id)?;
        info!("try to connect to worker with socket in {}", socket_path.display());
        loop {
            if let Ok(stream) = UnixStream::connect(&socket_path) {
                self.stream = Some(stream);
                break;
            }
            thread::sleep(Duration::from_millis(1));
            // TODO: handle different kinds of errors
        }

        Ok(())
    }

    // for now: don't return a typed value here, only Ok(raw value) or an error
    pub fn run_query(&mut self, query: CtRRQuery) -> Result<String, Box<dyn Error>> {
        let raw_json = serde_json::to_string(&query)?;

        info!("send to worker {raw_json}\n");
        self.stream
            .as_mut()
            .expect("valid sending stream")
            .write_all(&format!("{raw_json}\n").into_bytes())?;
        // `clippy::unused_io_amount` catched we need write_all, not write

        let mut res = "".to_string();
        info!("wait to read");

        let mut reader = BufReader::new(self.stream.as_mut().expect("valid receiving stream"));
        reader.read_line(&mut res)?; // TODO: more robust reading/read all

        res = String::from(res.trim()); // trim newlines/whitespace!

        info!("res {res}");

        if !res.starts_with("error:") {
            Ok(res)
        } else {
            Err(format!("run_query ct rr worker error: {}", res).into())
        }
    }
}

impl RRDispatcher {
    pub fn new(ct_rr_args: CtRRArgs) -> RRDispatcher {
        RRDispatcher {
            stable: CtRRWorker::new("stable", &ct_rr_args.worker_exe, &ct_rr_args.rr_trace_folder),
            ct_rr_worker_exe: ct_rr_args.worker_exe.clone(),
            rr_trace_folder: ct_rr_args.rr_trace_folder.clone(),
        }
    }

    pub fn ensure_active_stable(&mut self) -> Result<(), Box<dyn Error>> {
        // start stable process if not active, store fields, setup ipc? store in stable
        if !self.stable.active {
            self.stable.start()?;
        }
        // check again:
        if !self.stable.active {
            return Err("stable started, but still not active without an obvious error".into());
        }

        Ok(())
    }

    fn load_location_directly(&mut self) -> Result<Location, Box<dyn Error>> {
        Ok(serde_json::from_str::<Location>(
            &self.stable.run_query(CtRRQuery::LoadLocation)?,
        )?)
    }
}

impl Replay for RRDispatcher {
    fn load_location(&mut self, _expr_loader: &mut ExprLoader) -> Result<Location, Box<dyn Error>> {
        self.ensure_active_stable()?;
        self.load_location_directly()
    }

    fn run_to_entry(&mut self) -> Result<(), Box<dyn Error>> {
        self.ensure_active_stable()?;
        let _ok = self.stable.run_query(CtRRQuery::RunToEntry)?;
        Ok(())
    }

    fn load_events(&mut self) -> Result<Events, Box<dyn Error>> {
        self.ensure_active_stable()?;
        warn!("TODO load_events rr");
        Ok(Events {
            events: vec![],
            first_events: vec![],
            contents: "".to_string(),
        })
    }

    fn step(&mut self, action: Action, forward: bool) -> Result<bool, Box<dyn Error>> {
        self.ensure_active_stable()?;
        let res = serde_json::from_str::<bool>(&self.stable.run_query(CtRRQuery::Step { action, forward })?)?;
        Ok(res)
    }

    fn load_locals(&mut self, arg: CtLoadLocalsArguments) -> Result<Vec<Variable>, Box<dyn Error>> {
        self.ensure_active_stable()?;
        let res = serde_json::from_str::<Vec<Variable>>(&self.stable.run_query(CtRRQuery::LoadLocals { arg })?)?;
        Ok(res)
    }

    fn load_value(&mut self, expression: &str) -> Result<ValueRecord, Box<dyn Error>> {
        self.ensure_active_stable()?;
        let res = serde_json::from_str::<ValueRecord>(&self.stable.run_query(CtRRQuery::LoadValue { expression })?)?;
        Ok(res)
    }

    fn load_return_value(&mut self) -> Result<ValueRecord, Box<dyn Error>> {
        self.ensure_active_stable()?;
        let res = serde_json::from_str::<ValueRecord>(&self.stable.run_query(CtRRQuery::LoadReturnValue)?)?;
        Ok(res)
    }

    fn load_step_events(&mut self, step_id: StepId, exact: bool) -> Vec<DbRecordEvent> {
        // TODO: maybe cache events directly in replay for now, and use the same logic for them as in Db?
        // or directly embed Db? or separate events in a separate EventList?
        vec![]
    }

    fn jump_to(&mut self, step_id: StepId) -> Result<bool, Box<dyn Error>> {
        // TODO
        todo!()
    }

    fn current_step_id(&mut self) -> StepId {
        // cache location or step_id and return
        // OR always load from worker
        // TODO: return result or do something else or cache ?
        let location = self.load_location_directly().expect("access to step_id");
        StepId(location.rr_ticks.0)
    }
}
