use std::error::Error;
use std::io::Write;
use std::io::{BufRead, BufReader};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::Duration;

use log::info;

use crate::paths::ct_rr_worker_socket_path;
use crate::query::CtRRQuery;

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
    sending_stream: Option<UnixStream>,
    receiving_stream: Option<UnixStream>,
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
            sending_stream: None,
            receiving_stream: None,
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

        // sending socket:
        let sending_socket_path = ct_rr_worker_socket_path("backend", &self.name, run_id)?;
        info!(
            "try to connect to worker with sending socket in {}",
            sending_socket_path.display()
        );
        loop {
            if let Ok(sending_stream) = UnixStream::connect(&sending_socket_path) {
                self.sending_stream = Some(sending_stream);
                break;
            }
            thread::sleep(Duration::from_millis(1));
            // TODO: handle different kinds of errors
        }
        // receiving socket:
        let receiving_socket_path = ct_rr_worker_socket_path("worker", &self.name, run_id)?;
        info!(
            "try to connect to worker with receiving socket in {}",
            receiving_socket_path.display()
        );
        loop {
            if let Ok(receiving_stream) = UnixStream::connect(&receiving_socket_path) {
                self.receiving_stream = Some(receiving_stream);
                break;
            }
            thread::sleep(Duration::from_millis(1));
            // TODO: handle different kinds of errors
        }

        Ok(())
    }

    // for now: don't return a typed value here, only ok or an error
    pub fn run_query(&mut self, query: CtRRQuery) -> Result<(), Box<dyn Error>> {
        let raw_json = serde_json::to_string(&query)?;

        info!("send to worker {raw_json}\n");
        self.sending_stream
            .as_mut()
            .expect("valid sending stream")
            .write(&format!("{raw_json}\n").into_bytes())?;

        let mut res = "".to_string();
        info!("wait to read");

        let mut reader = BufReader::new(self.receiving_stream.as_mut().expect("valid receiving stream"));
        reader.read_line(&mut res)?;

        res = String::from(res.trim()); // trim newlines/whitespace!

        info!("res {res}");

        if res == "ok" {
            Ok(())
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

    pub fn run_to_entry(&mut self) -> Result<(), Box<dyn Error>> {
        self.ensure_active_stable()?;
        self.stable.run_query(CtRRQuery::RunToEntry)
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
}
