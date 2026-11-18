//! A replay query answered at once does not sweep `/proc`.
//!
//! The busy-worker wait (`WorkerProgress` in `recreator_session.rs`) measures
//! the CPU time of the worker's processes, and finding the processes rr
//! traces reads the status of every process on the host. Taken for every
//! query, that sweep cost a Pascal loop's flow about ten times its replay
//! time per step on a busy host (2026-11-18). It is taken only once an
//! answer is late; this test holds a prompt answer to no sweep, and checks
//! that a late answer to a query that may wait does sweep, so the count is
//! known to see sweeps.
//!
//! The worker on the other end is this test, listening on the socket path
//! the session computes, so it answers at chosen times; the spawned
//! "worker" process is a `/bin/sh` stub that only stays alive (justified:
//! what is measured is the session's own work around a query, and the real
//! worker cannot be made to answer late on demand). This file holds one test
//! because the sweep count is process-wide.

#![cfg(target_os = "linux")]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;
use std::thread;
use std::time::Duration;

use db_backend::paths::recreator_socket_path;
use db_backend::query::ReplayQuery;
use db_backend::recreator_session::{ReplayWorker, proc_sweeps};
use db_backend::task::Action;

#[test]
fn a_query_answered_at_once_does_not_sweep_proc() {
    let temp = tempfile::tempdir().expect("create temp dir");
    let stub = temp.path().join("idle-worker");
    std::fs::write(&stub, "#!/bin/sh\nexec sleep 120\n").expect("write stub worker");
    std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o755)).expect("chmod stub worker");
    let trace_folder = temp.path().join("trace");
    std::fs::create_dir_all(&trace_folder).expect("create trace folder");

    // `stable` is the replay that holds the user's position: its motions
    // (a `Step`) are the queries that may wait on a busy worker.
    let worker_name = "stable";
    let run_id = std::process::id().to_string();
    let socket_path = recreator_socket_path("", worker_name, 0, &run_id).expect("socket path");
    let _ = std::fs::remove_file(&socket_path);
    let listener = UnixListener::bind(&socket_path).expect("bind worker socket");

    // The worker: answers its first 20 queries at once, then one a second late.
    let server = thread::spawn(move || {
        let Ok((stream, _)) = listener.accept() else {
            return;
        };
        let mut writer = stream.try_clone().expect("clone worker stream");
        let mut reader = BufReader::new(stream);
        let mut line = String::new();
        let mut index = 0;
        while reader.read_line(&mut line).map(|n| n > 0).unwrap_or(false) {
            if index == 20 {
                thread::sleep(Duration::from_secs(1));
            }
            if writer.write_all(format!("\"answer {index}\"\n").as_bytes()).is_err() {
                return;
            }
            index += 1;
            line.clear();
        }
    });

    let mut worker = ReplayWorker::new(worker_name, 0, &stub, &trace_folder);
    worker.start().expect("the session connects to the worker socket");
    let step = || ReplayQuery::Step {
        action: Action::Next,
        forward: true,
    };

    let before = proc_sweeps();
    for _ in 0..20 {
        worker.dispatch_replay_query(step()).expect("a prompt answer");
    }
    let prompt = proc_sweeps() - before;

    let before = proc_sweeps();
    worker
        .dispatch_replay_query(step())
        .expect("a late answer within the timeout");
    let late = proc_sweeps() - before;

    drop(worker);
    let _ = server.join();
    if let Some(run_dir) = socket_path.parent() {
        let _ = std::fs::remove_dir_all(run_dir);
    }

    assert_eq!(prompt, 0, "20 queries answered at once swept /proc {prompt} times");
    assert!(
        late >= 1,
        "a motion answered a second late did not sweep /proc, so the count cannot see a sweep"
    );
}
