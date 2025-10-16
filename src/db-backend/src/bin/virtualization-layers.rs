#![allow(clippy::enum_variant_names)]
#![deny(clippy::panic)]
#![deny(clippy::unwrap_used)]
#![deny(clippy::expect_used)]
#![deny(clippy::exit)]
#![allow(dead_code)]
// TODO: deny when we cleanup
// dead code usage/add only
// specific allows
// #![deny(dead_code)]
// use std::collections::HashMap;
use clap::Parser;
// use log::info;
use std::error::Error;
use std::fs;
use std::io::Write;
use std::path::PathBuf;
// use std::sync::mpsc;

extern crate db_backend;
use db_backend::core::Core;
use db_backend::db::Db;
use db_backend::handler::Handler;
use db_backend::rr_dispatcher::CtRRArgs;
use db_backend::task::TraceKind;
// use db_backend::receiver::Receiver;
// use db_backend::response::Response;

/// virtualization layers for event log/trace/calltrace(maybe others)
#[derive(Parser, Debug)]
#[command(version, about, long_about = None)]
struct Args {
    /// socket path to communicate on
    socket_path: PathBuf,
    /// codetracer unique run instance id
    caller_process_pid: usize,
}

fn main() -> Result<(), Box<dyn Error>> {
    let cli = Args::parse();

    let core = Core {
        socket: None,
        caller_process_pid: cli.caller_process_pid,
    };

    let run_dir = core.run_dir()?;
    fs::create_dir_all(&run_dir)?;
    let log_path = run_dir.join("virtualization_virtualization_0.log");

    let mut builder = env_logger::Builder::from_default_env();
    // credit to https://github.com/rust-cli/env_logger/issues/125#issuecomment-1406333500
    // and https://github.com/rust-cli/env_logger/issues/125#issuecomment-1582209797
    // for file targetting code
    #[allow(clippy::expect_used)]
    let target = Box::new(fs::File::create(log_path).expect("Can't create file"));

    builder
        .target(env_logger::Target::Pipe(target))
        .format(|buf, record| {
            writeln!(
                buf,
                "{} - {}:{} {}",
                record.level(),
                record.file().unwrap_or("<unknown>"),
                record.line().unwrap_or(0),
                record.args()
            )
        })
        .filter(None, log::LevelFilter::Info)
        .init();

    // TODO: DAP
    // let mut receiver = Receiver::new();
    // let (tx, _rx): (mpsc::Sender<Response>, mpsc::Receiver<Response>) = mpsc::channel();

    // let socket_path = cli.socket_path.clone();

    // a placeholder, we won't use it
    let db = Db::new(&PathBuf::from(""));
    // receiver.setup_for_virtualization_layers(&cli.socket_path, cli.caller_process_pid)?;

    let mut _handler = Handler::construct(TraceKind::DB, CtRRArgs::default(), Box::new(db), true);

    // receiver.receive_loop(&mut handler)?;

    Ok(())
}
