//! A replay query whose worker is slow but still working is waited for; the
//! read timeout gives up only on a worker that stopped working.
//!
//! On a loaded host an rr `RunToEntry` or reverse continue took more than the
//! 10 s read timeout. `dispatch_replay_query` then stopped the worker, and the
//! next query found none: the desktop's value-origin walk failed with "the
//! replay worker is not connected", and a run-to-entry ended where it began.
//! The wait now goes on while the worker's process tree uses CPU
//! (`WorkerProgress` in `recreator_session.rs`); an idle worker still times
//! out (`replay_worker_query_timeout_test.rs`).
//!
//! The worker on the other end is this test itself, listening on the socket
//! path the session computes, so the timing is exact. The spawned "worker"
//! process is a `/bin/sh` stub that spins, using CPU the way a replaying rr
//! does; it stands in for the real `ct-native-replay` (justified: the defect
//! is in the client's wait, which needs a server whose answer can be delayed
//! on demand while its process is busy, and the real worker cannot be made
//! slow on demand). This file holds one test because the query timeout is
//! read from the process environment.

#![cfg(target_os = "linux")]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::Duration;

use db_backend::paths::recreator_socket_path;
use db_backend::query::ReplayQuery;
use db_backend::recreator_session::ReplayWorker;

fn write_busy_worker(dir: &Path) -> PathBuf {
    let path = dir.join("busy-worker");
    std::fs::write(&path, "#!/bin/sh\nwhile :; do :; done\n").expect("write stub worker");
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).expect("chmod stub worker");
    path
}

#[test]
fn a_slow_answer_from_a_working_worker_is_waited_for() {
    // SAFETY: this test binary holds this single test, and the variables are
    // set before any thread that reads them exists.
    unsafe {
        std::env::set_var("CODETRACER_REPLAY_QUERY_TIMEOUT_SECS", "1");
        std::env::set_var("CODETRACER_REPLAY_QUERY_MAX_SECS", "30");
    }

    let temp = tempfile::tempdir().expect("create temp dir");
    let stub = write_busy_worker(temp.path());
    let trace_folder = temp.path().join("trace");
    std::fs::create_dir_all(&trace_folder).expect("create trace folder");

    let worker_name = format!("busy-answer-{}", std::process::id());
    let socket_path = recreator_socket_path("", &worker_name, 0, &std::process::id().to_string()).expect("socket path");
    let _ = std::fs::remove_file(&socket_path);
    let listener = UnixListener::bind(&socket_path).expect("bind worker socket");

    // The worker: answers the first query three seconds late (three read
    // timeouts), and every later query at once.
    let server = thread::spawn(move || {
        let Ok((stream, _)) = listener.accept() else {
            return;
        };
        let mut writer = stream.try_clone().expect("clone worker stream");
        let mut reader = BufReader::new(stream);
        let mut index = 0;
        let mut line = String::new();
        while reader.read_line(&mut line).map(|n| n > 0).unwrap_or(false) {
            if index == 0 {
                thread::sleep(Duration::from_secs(3));
            }
            let answer = format!("\"answer to query {index}\"\n");
            if writer.write_all(answer.as_bytes()).is_err() {
                return;
            }
            index += 1;
            line.clear();
        }
    });

    let mut worker = ReplayWorker::new(&worker_name, 0, &stub, &trace_folder);
    worker.start().expect("the session connects to the worker socket");

    let first = worker.dispatch_replay_query(ReplayQuery::LoadLocation);
    assert_eq!(
        first.as_deref().map_err(|e| e.to_string()),
        Ok("\"answer to query 0\""),
        "a worker that is still working must be waited for past the read timeout"
    );
    let second = worker.dispatch_replay_query(ReplayQuery::LoadLocation);
    assert_eq!(
        second.as_deref().map_err(|e| e.to_string()),
        Ok("\"answer to query 1\""),
        "the connection must still be paired after the slow answer"
    );

    drop(worker);
    let _ = server.join();
    if let Some(run_dir) = socket_path.parent() {
        let _ = std::fs::remove_dir_all(run_dir);
    }
}
