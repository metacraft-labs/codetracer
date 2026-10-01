//! A replay query that times out must not leave its late answer to be read as
//! the answer to the next query.
//!
//! The replay-worker protocol is one JSON line out, one line back, with no
//! request ids: an answer is matched to its query only by order. When
//! `dispatch_replay_query` gives up on a slow answer, the worker is still
//! working on it and writes it later. Unless that connection is abandoned,
//! the next query reads the previous query's answer, every answer after that
//! is shifted by one, and each caller parses a reply meant for someone else --
//! a flow whose locations all decode to `<unknown>:0`.
//!
//! The worker on the other end is this test itself, listening on the socket
//! path the session computes, so the timing is exact and nothing else runs.
//! The spawned "worker" process is a `/bin/sh` stub that only stays alive; it
//! stands in for the real `ct-native-replay` (justified: the defect is in the
//! client's handling of a late answer, which needs a server whose answers can
//! be delayed on demand, and the real worker cannot be made slow on demand).
//! This file holds one test because the query timeout is read from the
//! process environment.

#![cfg(unix)]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::Duration;

use db_backend::paths::recreator_socket_path;
use db_backend::query::ReplayQuery;
use db_backend::recreator_session::ReplayWorker;

fn write_idle_worker(dir: &Path) -> PathBuf {
    let path = dir.join("idle-worker");
    std::fs::write(&path, "#!/bin/sh\nexec sleep 120\n").expect("write stub worker");
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).expect("chmod stub worker");
    path
}

#[test]
fn a_late_answer_is_never_returned_for_the_next_query() {
    // SAFETY: this test binary holds this single test, and the variable is
    // set before any thread that reads it exists.
    unsafe { std::env::set_var("CODETRACER_REPLAY_QUERY_TIMEOUT_SECS", "1") };

    let temp = tempfile::tempdir().expect("create temp dir");
    let stub = write_idle_worker(temp.path());
    let trace_folder = temp.path().join("trace");
    std::fs::create_dir_all(&trace_folder).expect("create trace folder");

    let worker_name = format!("late-answer-{}", std::process::id());
    let socket_path = recreator_socket_path("", &worker_name, 0, &std::process::id().to_string()).expect("socket path");
    let _ = std::fs::remove_file(&socket_path);
    let listener = UnixListener::bind(&socket_path).expect("bind worker socket");

    // The worker: answers the first query two seconds late (past the one
    // second timeout), and every later query at once.
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
                thread::sleep(Duration::from_secs(2));
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
    assert!(
        first.is_err(),
        "the first answer arrives after the timeout, so the first query must fail; got {first:?}"
    );

    // Let the late answer reach the connection before the next query is sent.
    thread::sleep(Duration::from_secs(2));

    let second = worker.dispatch_replay_query(ReplayQuery::LoadLocation);
    if let Ok(answer) = &second {
        assert_ne!(
            answer, "\"answer to query 0\"",
            "the second query was answered with the first query's late reply: \
             the query/answer pairing is shifted by one from here on"
        );
    }

    drop(worker);
    let _ = server.join();
    // The run directory is this test process's own (named after its pid):
    // it holds the socket and the stub's log, and nothing else uses it.
    if let Some(run_dir) = socket_path.parent() {
        let _ = std::fs::remove_dir_all(run_dir);
    }
}
