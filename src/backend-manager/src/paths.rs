use std::env;
use std::path::PathBuf;
use std::sync::{LazyLock, Mutex};

pub struct Paths {
    pub tmp_path: PathBuf,
}

impl Paths {
    /// Returns the well-known path for the daemon's Unix socket.
    ///
    /// Clients connect to this socket when communicating with a daemon-mode
    /// backend-manager instance.
    pub fn daemon_socket_path(&self) -> PathBuf {
        self.tmp_path.join("daemon.sock")
    }

    /// Returns the path where the daemon writes its PID file.
    ///
    /// The PID file is used to detect whether a daemon is already running and
    /// to implement `daemon stop` / `daemon status` subcommands.
    pub fn daemon_pid_path(&self) -> PathBuf {
        self.tmp_path.join("daemon.pid")
    }
}

impl Default for Paths {
    fn default() -> Self {
        let tmpdir: PathBuf = if cfg!(target_os = "macos") {
            PathBuf::from(env::var("HOME").unwrap_or("/".to_string()))
                .join("Library/Caches/com.codetracer.CodeTracer/")
        } else {
            env::temp_dir().join("codetracer/")
        };
        Self {
            tmp_path: PathBuf::from(&tmpdir),
        }
    }
}

pub static CODETRACER_PATHS: LazyLock<Mutex<Paths>> =
    LazyLock::new(|| Mutex::new(Paths::default()));
