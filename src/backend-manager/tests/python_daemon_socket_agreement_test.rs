//! The Python API finds the daemon the CLI starts, whatever moved its socket.
//!
//! The daemon resolves its socket in one function,
//! `DaemonConfig::daemon_paths` (`src/config.rs`): `CODETRACER_DAEMON_SOCKET`,
//! else `socket_path` in the daemon config file, else `daemon.sock` in
//! `CODETRACER_TMP_PATH`, else in `$CODETRACER_HOME/tmp`, else in the per-OS
//! default. The Python API (`python-api/codetracer/connection.py`,
//! `default_daemon_socket_path`) cannot call it and mirrors it.
//!
//! The defect this guards against: the Python default was hard-coded to
//! `/tmp/codetracer/daemon.sock` (`~/Library/Caches/...` on macOS), so with any
//! of those overrides — `CODETRACER_HOME` included, which every test harness
//! sets — `open_trace(path)` without an explicit `daemon_socket` looked for a
//! daemon where none listens and failed with "Cannot connect to daemon".
//!
//! Each case starts the real daemon with `session-manager daemon connect`
//! (which auto-starts it) under one set of overrides, then runs the real
//! Python API in the same environment: it must name the same socket and get
//! an answer from the daemon over it. No mocks; no `replay-server` is needed,
//! because the trace the script asks for does not exist and the daemon's
//! refusal is the proof that it was reached.
//!
//! The per-OS default (no `CODETRACER_HOME`) is not started here: the daemon
//! would then write its log into the developer's profile. The Python side of
//! that branch is covered by `python-api/tests/test_daemon_socket_path.py`.
//!
//! Unix only: the Python client speaks AF_UNIX, and on Windows the "socket" is
//! a TCP port file.
//!
//! Needs `python3` on `PATH` (the dev shell provides it), as the daemon's
//! `exec_script` does.
#![cfg(unix)]

use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant};

const SESSION_MANAGER: &str = env!("CARGO_BIN_EXE_session-manager");

/// The overrides that decide where the daemon listens.
#[derive(Default)]
struct Overrides {
    socket: Option<PathBuf>,
    config_file: Option<PathBuf>,
    tmp_path: Option<PathBuf>,
}

/// One scratch environment with a private `CODETRACER_HOME` and `TMPDIR`, so
/// nothing reaches the developer's profile or the shared `/tmp/codetracer`.
struct Scratch {
    _dir: tempfile::TempDir,
    root: PathBuf,
    overrides: Overrides,
    /// Where the daemon must listen under `overrides`.
    expected_socket: PathBuf,
}

impl Scratch {
    fn new(configure: impl FnOnce(&Path) -> (Overrides, PathBuf)) -> Scratch {
        let dir = tempfile::tempdir().expect("scratch dir");
        let root = dir.path().to_path_buf();
        let (overrides, expected_socket) = configure(&root);
        Scratch {
            _dir: dir,
            root,
            overrides,
            expected_socket,
        }
    }

    fn home(&self) -> PathBuf {
        self.root.join("home")
    }

    /// The PID file the daemon writes: `<socket>.pid` beside an overridden
    /// socket, `daemon.pid` beside the default `daemon.sock` (the same rule).
    fn pid_file(&self) -> PathBuf {
        self.expected_socket.with_extension("pid")
    }

    /// `cmd` with exactly this case's environment: nothing inherited may
    /// decide the paths.
    fn command(&self, program: &str) -> Command {
        let mut cmd = Command::new(program);
        cmd.env("TMPDIR", self.root.join("tmpdir"))
            .env("CODETRACER_HOME", self.home())
            .env_remove("CODETRACER_DAEMON_SOCK")
            .env_remove("CODETRACER_DAEMON_SOCKET")
            .env_remove("CODETRACER_DAEMON_CONFIG")
            .env_remove("CODETRACER_TMP_PATH")
            .stdin(Stdio::null());
        if let Some(socket) = &self.overrides.socket {
            cmd.env("CODETRACER_DAEMON_SOCKET", socket);
        }
        if let Some(config) = &self.overrides.config_file {
            cmd.env("CODETRACER_DAEMON_CONFIG", config);
        }
        if let Some(tmp) = &self.overrides.tmp_path {
            cmd.env("CODETRACER_TMP_PATH", tmp);
        }
        cmd
    }

    fn session_manager(&self, args: &[&str]) -> Output {
        self.command(SESSION_MANAGER)
            .args(args)
            .output()
            .expect("session-manager runs")
    }

    /// Run the Python API with no explicit socket: print the socket it
    /// resolved, then ask the daemon over it for a trace that does not exist.
    fn python_client(&self) -> Output {
        let python_api = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../python-api");
        let script = r#"
import sys
sys.path.insert(0, sys.argv[1])
from codetracer.connection import DaemonConnection, default_daemon_socket_path
from codetracer.exceptions import TraceError
print("resolved", default_daemon_socket_path(), flush=True)
conn = DaemonConnection()
try:
    conn.connect()
except TraceError as e:
    print("unreachable", e, flush=True)
    sys.exit(3)
reply = conn.send_request("ct/open-trace", {"tracePath": sys.argv[2]})
print("reply", reply.get("type"), reply.get("success"), flush=True)
conn.close()
"#;
        self.command("python3")
            // Isolated mode: no PYTHON* variables, no user site-packages, no
            // working directory on sys.path (as the daemon runs scripts).
            .args(["-I", "-B", "-c", script])
            .arg(&python_api)
            .arg(self.root.join("no-such-trace"))
            .output()
            .expect("python3 runs (it is on PATH in the dev shell)")
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
    /// `daemon stop`.
    fn drop(&mut self) {
        if let Some(pid) = self.daemon_pid() {
            // SAFETY: plain kill(2) on a PID this test's daemon wrote.
            unsafe {
                libc::kill(pid, libc::SIGKILL);
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

/// Start the daemon under `s`'s overrides, check the Python API reaches it,
/// stop it.
fn python_finds_the_daemon(s: &Scratch) {
    let out = s.session_manager(&["daemon", "connect"]);
    assert!(out.status.success(), "daemon connect: {}", text(&out));
    assert!(
        s.expected_socket.exists(),
        "the daemon is not listening at {}",
        s.expected_socket.display()
    );
    let pid = s.daemon_pid().expect("the daemon's PID file");

    let out = s.python_client();
    let report = text(&out);
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        stdout.contains(&format!("resolved {}\n", s.expected_socket.display())),
        "the Python API resolved another socket than the daemon's ({}):\n{report}",
        s.expected_socket.display()
    );
    assert_eq!(out.status.code(), Some(0), "{report}");
    assert!(
        stdout.contains("reply response False"),
        "the daemon should refuse the missing trace:\n{report}"
    );

    let out = s.session_manager(&["daemon", "stop"]);
    assert!(out.status.success(), "daemon stop: {}", text(&out));
    let started = Instant::now();
    while alive(pid) {
        assert!(
            started.elapsed() < Duration::from_secs(10),
            "daemon {pid} still running 10 s after `daemon stop`"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn python_finds_the_daemon_in_codetracer_home() {
    let s = Scratch::new(|root| {
        (
            Overrides::default(),
            root.join("home").join("tmp").join("daemon.sock"),
        )
    });
    python_finds_the_daemon(&s);
}

#[test]
fn python_finds_the_daemon_in_codetracer_tmp_path() {
    let s = Scratch::new(|root| {
        let tmp = root.join("electron-tmp");
        (
            Overrides {
                tmp_path: Some(tmp.clone()),
                ..Overrides::default()
            },
            tmp.join("daemon.sock"),
        )
    });
    python_finds_the_daemon(&s);
}

/// `socket_path` in `$CODETRACER_HOME/config/daemon.conf` outranks
/// `CODETRACER_TMP_PATH`. The file is written the way `parse_config_file`
/// reads it: a comment, padding around key and value, a later key winning.
#[test]
fn python_finds_the_daemon_at_the_configured_socket() {
    let s = Scratch::new(|root| {
        let socket = root.join("from-config").join("d.sock");
        let config_dir = root.join("home").join("config");
        std::fs::create_dir_all(&config_dir).unwrap();
        std::fs::write(
            config_dir.join("daemon.conf"),
            format!(
                "# where the daemon listens\nsocket_path = {}/first.sock\n  socket_path\t=  {}  \r\nmax_sessions = 3\n",
                root.display(),
                socket.display()
            ),
        )
        .unwrap();
        (
            Overrides {
                tmp_path: Some(root.join("electron-tmp")),
                ..Overrides::default()
            },
            socket,
        )
    });
    python_finds_the_daemon(&s);
}

/// `CODETRACER_DAEMON_CONFIG` names the config file instead.
#[test]
fn python_finds_the_daemon_through_codetracer_daemon_config() {
    let s = Scratch::new(|root| {
        let socket = root.join("elsewhere").join("d.sock");
        let config = root.join("custom.conf");
        std::fs::write(&config, format!("socket_path={}\n", socket.display())).unwrap();
        (
            Overrides {
                config_file: Some(config),
                ..Overrides::default()
            },
            socket,
        )
    });
    python_finds_the_daemon(&s);
}

/// `CODETRACER_DAEMON_SOCKET` outranks the config file.
#[test]
fn python_finds_the_daemon_at_codetracer_daemon_socket() {
    let s = Scratch::new(|root| {
        let socket = root.join("override").join("daemon.sock");
        let config = root.join("custom.conf");
        std::fs::write(
            &config,
            format!("socket_path={}/loser.sock\n", root.display()),
        )
        .unwrap();
        (
            Overrides {
                socket: Some(socket.clone()),
                config_file: Some(config),
                tmp_path: Some(root.join("electron-tmp")),
            },
            socket,
        )
    });
    python_finds_the_daemon(&s);
}
