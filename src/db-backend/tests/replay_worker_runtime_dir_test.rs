//! A replay worker is told which directory its spawner waits for its socket in.
//!
//! The spawner (this crate's `ReplayWorker::start`) connects to
//! `<runtime dir>/run-<run id>/ct_native_replay_<name>_<index>_from_.sock`,
//! and the worker (`ct-native-replay`, a separate program) creates it. Both
//! resolve the runtime directory: `$CODETRACER_RUNTIME_DIR`, else
//! `$XDG_RUNTIME_DIR/codetracer`, else a fallback, and the fallbacks differ
//! (`$CODETRACER_HOME/tmp` here, `$TMPDIR/codetracer` in the worker). On a
//! host without `$XDG_RUNTIME_DIR`, such as a CI runner's service, a test that
//! set `CODETRACER_HOME` saw the worker listen in one directory while the
//! spawner waited in the other until the test timed out. The spawner now names
//! the directory to the worker in `$CODETRACER_RUNTIME_DIR`.
//!
//! This test reproduces that environment (no `$XDG_RUNTIME_DIR`, no
//! `$CODETRACER_RUNTIME_DIR`, `$CODETRACER_HOME` and `$TMPDIR` in different
//! places) and checks that the worker's environment names the directory the
//! spawner connects in. The spawned worker is a `/bin/sh` stub that records
//! its environment and stays alive; it stands in for the real `ct-native-replay`
//! (justified: the real worker needs a native recording, which needs a host
//! with CPUID faulting, and what is under test is what the spawner hands its
//! child, which a stub observes exactly). The socket is this test's own
//! listener at the path the spawner computes. The real worker over a real
//! recording is the CPUID-gated `c_mcr_tracepoint_test` and backend-manager's
//! `mcp_exec_script_goto_geid_native_recording`. This file holds one test
//! because the paths are read from the process environment once.

#![cfg(unix)]

use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use db_backend::paths::{CODETRACER_RUNTIME_DIR_ENV, recreator_socket_path, runtime_base_dir};
use db_backend::recreator_session::ReplayWorker;

/// A worker that writes `$CODETRACER_RUNTIME_DIR` (or `<unset>`) to `out`, then
/// stays alive until the session ends.
fn write_env_recording_worker(dir: &Path, out: &Path) -> PathBuf {
    let path = dir.join("env-worker");
    let script = format!(
        "#!/bin/sh\nprintf '%s' \"${{{var}-<unset>}}\" > '{out}.tmp' && mv '{out}.tmp' '{out}'\nexec sleep 120\n",
        var = CODETRACER_RUNTIME_DIR_ENV,
        out = out.display()
    );
    std::fs::write(&path, script).expect("write stub worker");
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).expect("chmod stub worker");
    path
}

#[test]
fn the_worker_is_told_the_runtime_directory_its_spawner_waits_in() {
    let temp = tempfile::tempdir().expect("create temp dir");
    let ct_home = temp.path().join("h");
    let other_tmp = temp.path().join("t");
    std::fs::create_dir_all(&other_tmp).expect("create TMPDIR");
    // SAFETY: this test binary holds this single test, and the variables are
    // set before any thread that reads them exists and before the paths are
    // first resolved (`CODETRACER_PATHS` is computed on first use).
    unsafe {
        std::env::remove_var("XDG_RUNTIME_DIR");
        std::env::remove_var(CODETRACER_RUNTIME_DIR_ENV);
        std::env::set_var("CODETRACER_HOME", &ct_home);
        std::env::set_var("TMPDIR", &other_tmp);
    }

    // The CI runner's case: the spawner resolves under CODETRACER_HOME, not
    // under XDG_RUNTIME_DIR, and not under TMPDIR (the worker's own fallback).
    let base = runtime_base_dir().expect("runtime base dir");
    assert!(
        base.starts_with(&ct_home),
        "with no XDG_RUNTIME_DIR the spawner's runtime dir is under CODETRACER_HOME, got {}",
        base.display()
    );

    let out = temp.path().join("worker-env");
    let stub = write_env_recording_worker(temp.path(), &out);
    let trace_folder = temp.path().join("trace");
    std::fs::create_dir_all(&trace_folder).expect("create trace folder");

    let worker_name = format!("runtime-dir-{}", std::process::id());
    let socket_path = recreator_socket_path("", &worker_name, 0, &std::process::id().to_string()).expect("socket path");
    let _ = std::fs::remove_file(&socket_path);
    let _listener = UnixListener::bind(&socket_path).expect("bind worker socket");

    let mut worker = ReplayWorker::new(&worker_name, 0, &stub, &trace_folder);
    worker.start().expect("the session connects to the worker socket");

    let deadline = Instant::now() + Duration::from_secs(20);
    while !out.exists() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(20));
    }
    let seen = std::fs::read_to_string(&out).expect("the stub worker recorded its environment");
    drop(worker);

    assert_eq!(
        PathBuf::from(&seen),
        base,
        "the worker must be told the runtime directory its spawner connects in"
    );
    assert_eq!(
        socket_path.parent().and_then(Path::parent),
        Some(base.as_path()),
        "the spawner's socket is in a run directory directly under that runtime directory"
    );
}
