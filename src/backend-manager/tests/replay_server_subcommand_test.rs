//! The daemon starts the replay backend as `dap-server` whatever the
//! directory it was built in is called, and starts its own mock DAP backend
//! only when the explicit test flag asks for it.
//!
//! `ct/open-trace` used to pick the mock whenever the backend command's path
//! contained `backend-manager` or `session-manager`.  A real `replay-server`
//! built in a workspace directory named, say,
//! `fix-non-gui-lane-runs-backend-manager-record` was therefore started as
//! `replay-server mock-dap-backend <socket>`, which it does not have, and
//! every trace open timed out.  The first test reproduces exactly that: the
//! real `replay-server` is reached through a directory whose path contains
//! both words, and the trace must open.
//!
//! ## What is real, and the one thing that is not a CodeTracer component
//!
//! The daemon, `ct trace mcp` and the `replay-server` are the production
//! binaries over their real transports, and the recording is written by the
//! production CTFS writer.  No CodeTracer component is mocked.
//!
//! The arguments the daemon starts the backend with are observed through a
//! two-line `sh` script, named `replay-server`, in that directory: it
//! appends its arguments to a log and `exec`s the program the test names,
//! with the same arguments.  It answers nothing and alters nothing; it
//! exists so a failure names the subcommand the daemon chose instead of
//! only timing out.  It is a script because the daemon starts the backend
//! as a separate executable.
//!
//! A missing `replay-server` fails the test.  It is never a skip.

#![cfg(unix)]
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

#[path = "support/mcp_harness.rs"]
mod mcp_harness;

use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::time::Duration;

use mcp_harness::*;
use serde_json::json;

/// The directory the backend command is reached through: every word the
/// daemon once read as "this is the session manager" is in it.
const MISLEADING_DIR: &str = "fix-backend-manager/session-manager";

/// A directory with neither word, so the mock can only be chosen by the
/// flag.
const NEUTRAL_DIR: &str = "neutral";

/// Records the arguments, one per line and a blank line after each start,
/// then runs `$CT_TEST_EXEC` with them.
const ARGV_TAP: &str = "#!/bin/sh\n\
printf '%s\\n' \"$@\" '' >> \"$CT_TEST_ARGV_LOG\"\n\
exec \"$CT_TEST_EXEC\" \"$@\"\n";

const APP_SOURCE: &str =
    "def main():\n    total = 0\n    for i in range(3):\n        total += i\n    return total\n";

/// What one test sets up: a recording, the tap and its log.
struct Setup {
    _root: tempfile::TempDir,
    root: PathBuf,
    trace_dir: PathBuf,
    tap: PathBuf,
    argv_log: PathBuf,
}

fn setup(prefix: &str, tap_dir: &str) -> Setup {
    use std::os::unix::fs::PermissionsExt;
    let (_root, root) = short_root(prefix);
    let workdir = root.join("project");
    std::fs::create_dir_all(&workdir).unwrap();
    let app = workdir.join("app.py");
    std::fs::write(&app, APP_SOURCE).unwrap();
    let trace_dir = root.join("trace");
    std::fs::create_dir_all(&trace_dir).unwrap();
    write_recording(&trace_dir, &workdir, &app, &[]);

    let tap_dir = root.join(tap_dir);
    std::fs::create_dir_all(&tap_dir).unwrap();
    let tap = tap_dir.join("replay-server");
    std::fs::write(&tap, ARGV_TAP).unwrap();
    std::fs::set_permissions(&tap, std::fs::Permissions::from_mode(0o755)).unwrap();
    let argv_log = root.join("argv.log");
    Setup {
        _root,
        root,
        trace_dir,
        tap,
        argv_log,
    }
}

/// The first argument of every backend start the tap logged.
fn subcommands(argv_log: &Path) -> Vec<String> {
    std::fs::read_to_string(argv_log)
        .unwrap_or_default()
        .split("\n\n")
        .filter_map(|start| start.lines().next().map(str::to_owned))
        .collect()
}

/// `trace_info` for the recording through a daemon started with `env`
/// (`CODETRACER_REPLAY_SERVER_CMD` is the tap), bounded so a backend that
/// never connects fails this test instead of hanging it.  Returns the tool
/// result, or `None` on the bound.
async fn trace_info(
    setup: &Setup,
    exec: &Path,
    env: &[(&str, &OsStr)],
) -> Option<Result<String, String>> {
    let server = server_binary();
    let mut env = env.to_vec();
    env.push(("CT_TEST_ARGV_LOG", setup.argv_log.as_os_str()));
    env.push(("CT_TEST_EXEC", exec.as_os_str()));
    let (mut daemon, socket) = start_daemon_with_env(&server, &setup.root, &setup.tap, &env).await;
    let mut mcp = start_mcp(&server, &setup.root, &socket, &[]).await;
    let result = tokio::time::timeout(
        Duration::from_secs(60),
        mcp.call_tool("trace_info", json!({"trace_path": setup.trace_dir})),
    )
    .await
    .ok();
    mcp.stop().await;
    shutdown_daemon(&socket, &mut daemon).await;
    result
}

#[tokio::test]
async fn a_replay_server_under_a_backend_manager_directory_is_started_as_dap_server() {
    let replay_server = replay_server();
    let setup = setup("ct-subcmd-real-", MISLEADING_DIR);
    // Vacuity guard: the command the daemon is given contains both words.
    let tap_text = setup.tap.to_str().unwrap();
    assert!(tap_text.contains("backend-manager") && tap_text.contains("session-manager"));

    let result = trace_info(&setup, &replay_server, &[]).await;

    assert_eq!(
        subcommands(&setup.argv_log),
        ["dap-server"],
        "the backend starts the daemon made through {} (trace_info: {result:?})",
        setup.tap.display()
    );
    let info = result
        .expect("trace_info answered within 60 s")
        .expect("trace_info opened the recording");
    assert!(info.contains("app.py"), "trace_info: {info}");
}

#[tokio::test]
async fn the_mock_dap_backend_is_started_only_when_the_flag_asks_for_it() {
    // The tap sits in a directory with neither word, so only the flag can
    // select the mock.  It runs the session manager itself, which has the
    // mock.  Whether the mock can answer `trace_info` is not this test's
    // business; which subcommand the daemon starts is.
    let setup = setup("ct-subcmd-mock-", NEUTRAL_DIR);
    // Vacuity guard: no word in the command the daemon is given could
    // select the mock, so a pass is the flag's doing.
    let tap_text = setup.tap.to_str().unwrap();
    assert!(!tap_text.contains("backend-manager") && !tap_text.contains("session-manager"));

    let result = trace_info(
        &setup,
        &server_binary(),
        &[("CODETRACER_REPLAY_SERVER_MOCK_DAP", OsStr::new("1"))],
    )
    .await;

    assert_eq!(
        subcommands(&setup.argv_log),
        ["mock-dap-backend"],
        "the backend starts the daemon made (trace_info: {result:?})"
    );
}

#[tokio::test]
async fn a_flag_that_is_neither_1_nor_0_is_refused_and_nothing_is_started() {
    let replay_server = replay_server();
    let setup = setup("ct-subcmd-bad-", MISLEADING_DIR);

    let result = trace_info(
        &setup,
        &replay_server,
        &[("CODETRACER_REPLAY_SERVER_MOCK_DAP", OsStr::new("yes"))],
    )
    .await;

    let err = result
        .expect("trace_info answered within 60 s")
        .expect_err("a misspelt flag selects neither backend");
    assert!(
        err.contains("CODETRACER_REPLAY_SERVER_MOCK_DAP=yes"),
        "the refusal names the flag and its value: {err}"
    );
    assert!(subcommands(&setup.argv_log).is_empty());
}
