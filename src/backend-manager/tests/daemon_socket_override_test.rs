//! `CODETRACER_DAEMON_SOCKET` moves the daemon's socket for the CLI client
//! and the daemon it starts alike.
//!
//! The defect this guards against: the client verbs resolved the socket
//! from `CODETRACER_PATHS` alone, while `daemon start` honoured `CODETRACER_DAEMON_SOCKET`.  With the variable set
//! and no daemon running, `trace info` spawned a daemon that listened on the
//! override, polled the default path, and gave up after five seconds with
//! `timeout waiting for daemon to start`.  `daemon stop` and `daemon status`
//! looked in the wrong place in the same way.
//!
//! No mocks: the test drives the real `session-manager` binary (Cargo's
//! `CARGO_BIN_EXE_*`), which auto-starts the real daemon.  No `replay-server`
//! is needed: the trace given to `trace info` does not exist, so the daemon
//! answers `ct/open-trace` with an error, and that answer is the proof that
//! the client reached the daemon it started.
//!
//! Unix only: on Windows the "socket" is a TCP port file, and the paths are
//! resolved by the same function, but this test's liveness checks
//! (`kill(pid, 0)`) are POSIX.
#![cfg(unix)]

use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant};

const SESSION_MANAGER: &str = env!("CARGO_BIN_EXE_session-manager");

/// One scratch environment: a private `CODETRACER_HOME` (so the default
/// socket, were it used, lands in scratch rather than the developer's
/// profile) and an override socket in a directory that is NOT that default.
struct Scratch {
    _dir: tempfile::TempDir,
    root: PathBuf,
    socket: PathBuf,
}

impl Scratch {
    fn new() -> Scratch {
        let dir = tempfile::tempdir().expect("scratch dir");
        let root = dir.path().to_path_buf();
        // The parent does not exist yet: the client must create it.
        let socket = root.join("override").join("daemon.sock");
        Scratch {
            _dir: dir,
            root,
            socket,
        }
    }

    fn home(&self) -> PathBuf {
        self.root.join("home")
    }

    /// Where the socket would be without the override (`paths.rs`,
    /// `$CODETRACER_HOME/tmp`).
    fn default_socket(&self) -> PathBuf {
        self.home().join("tmp").join("daemon.sock")
    }

    /// The PID file the daemon writes next to an overridden socket.
    fn pid_file(&self) -> PathBuf {
        self.socket.with_extension("pid")
    }

    fn run(&self, args: &[&str]) -> Output {
        Command::new(SESSION_MANAGER)
            .args(args)
            .env("TMPDIR", &self.root)
            .env("CODETRACER_HOME", self.home())
            .env("CODETRACER_DAEMON_SOCKET", &self.socket)
            // Nothing else may decide the paths: no Electron tmp override, no
            // config file from the developer's profile.
            .env_remove("CODETRACER_TMP_PATH")
            .env_remove("CODETRACER_DAEMON_SOCK")
            .env("CODETRACER_DAEMON_CONFIG", self.root.join("no-such.conf"))
            .stdin(Stdio::null())
            .output()
            .expect("session-manager runs")
    }

    fn daemon_pid(&self) -> Option<i32> {
        std::fs::read_to_string(self.pid_file())
            .ok()?
            .trim()
            .parse()
            .ok()
    }
}

impl Drop for Scratch {
    /// Never leave a daemon behind, whether or not the test got as far as
    /// `daemon stop`.  Both the override's PID file and the default one are
    /// checked, so a regression that starts the daemon at the default path
    /// is cleaned up too.
    fn drop(&mut self) {
        for pid_file in [self.pid_file(), self.home().join("tmp").join("daemon.pid")] {
            if let Some(pid) = std::fs::read_to_string(&pid_file)
                .ok()
                .and_then(|s| s.trim().parse::<i32>().ok())
            {
                // SAFETY: plain kill(2) on a PID this test's daemon wrote.
                unsafe {
                    libc::kill(pid, libc::SIGKILL);
                }
            }
        }
    }
}

fn alive(pid: i32) -> bool {
    // SAFETY: signal 0 delivers nothing; it only checks existence.
    unsafe { libc::kill(pid, 0) == 0 }
}

fn text(out: &Output) -> String {
    format!(
        "exit {:?}\nstdout:\n{}\nstderr:\n{}",
        out.status.code(),
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    )
}

fn wait_until(what: &str, deadline: Duration, mut done: impl FnMut() -> bool) {
    let started = Instant::now();
    while !done() {
        assert!(started.elapsed() < deadline, "{what} within {deadline:?}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn cli_client_and_daemon_share_the_codetracer_daemon_socket_override() {
    let s = Scratch::new();
    let missing_trace: &Path = &s.root.join("no-such-trace");

    // Cold start: `trace info` auto-starts the daemon and must reach it on the
    // overridden socket.  Before the fix this exited 1 with "timeout waiting
    // for daemon to start".
    let out = s.run(&["trace", "info", missing_trace.to_str().unwrap()]);
    let report = text(&out);
    assert!(
        !report.contains("timeout waiting for daemon"),
        "the client did not find the daemon it started:\n{report}"
    );
    // The daemon answered: it refused to open a trace that does not exist.
    assert_eq!(out.status.code(), Some(1), "{report}");
    assert!(
        String::from_utf8_lossy(&out.stderr).starts_with("error: "),
        "expected the daemon's ct/open-trace refusal:\n{report}"
    );

    // The daemon is on the override, and its PID file sits beside it.
    assert!(s.socket.exists(), "no socket at {}", s.socket.display());
    let pid = s
        .daemon_pid()
        .expect("the daemon's PID file beside the socket");
    assert!(alive(pid), "daemon {pid} is not running");
    assert!(
        !s.default_socket().exists(),
        "a socket appeared at the default path {}",
        s.default_socket().display()
    );

    // A second client verb joins the same daemon instead of starting another.
    let out = s.run(&["daemon", "connect"]);
    assert!(out.status.success(), "{}", text(&out));
    assert_eq!(s.daemon_pid(), Some(pid), "a different daemon took over");

    // `daemon status` and `daemon stop` look in the same place.
    let out = s.run(&["daemon", "status"]);
    assert!(
        String::from_utf8_lossy(&out.stdout).contains(&format!("Daemon is running (PID {pid})")),
        "{}",
        text(&out)
    );
    let out = s.run(&["daemon", "stop"]);
    assert!(out.status.success(), "{}", text(&out));
    wait_until(
        "the daemon exits after `daemon stop`",
        Duration::from_secs(10),
        || !alive(pid),
    );
    assert!(!s.socket.exists(), "the daemon left its socket behind");
}
