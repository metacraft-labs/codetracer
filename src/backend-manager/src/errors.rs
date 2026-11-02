use std::{error::Error, fmt::Display};

#[derive(Debug)]
pub struct InvalidLengthHeader;

impl Display for InvalidLengthHeader {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Invalind Content-Length header!")
    }
}

impl Error for InvalidLengthHeader {}

#[derive(Debug)]
pub struct InvalidID(pub usize);

impl Display for InvalidID {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Replay with ID {} doesn't exist!", self.0)
    }
}

impl Error for InvalidID {}

#[cfg(unix)]
#[derive(Debug)]
pub struct SocketPathError;

#[cfg(unix)]
impl Display for SocketPathError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Can't get path for socket!")
    }
}

#[cfg(unix)]
impl Error for SocketPathError {}

/// A Unix socket path the kernel cannot bind: `sockaddr_un.sun_path` holds a
/// fixed number of bytes, including the terminating NUL (108 on Linux, 104 on
/// macOS and the BSDs; see unix(7)), and a longer path fails in `bind(2)`
/// with an error that names neither the path nor the limit.  Raised before
/// the bind, naming both, so a caller with a long `TMPDIR` or
/// `CODETRACER_DAEMON_SOCKET` learns which path to shorten.
#[cfg(unix)]
pub struct SocketPathTooLong {
    /// The path that was to be bound.
    pub path: std::path::PathBuf,
    /// Its length in bytes.
    pub len: usize,
    /// The longest path `sun_path` holds, in bytes.
    pub max: usize,
}

#[cfg(unix)]
impl Display for SocketPathTooLong {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "the Unix socket path {} is {} bytes, longer than the {} a socket address holds \
             (sun_path); use a shorter TMPDIR, CODETRACER_TMP_PATH or CODETRACER_DAEMON_SOCKET",
            self.path.display(),
            self.len,
            self.max
        )
    }
}

// `main` returning this error prints its `Debug` form; make that the
// message rather than a struct dump.
#[cfg(unix)]
impl std::fmt::Debug for SocketPathTooLong {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        Display::fmt(self, f)
    }
}

#[cfg(unix)]
impl Error for SocketPathTooLong {}

/// The daemon is already running (PID file exists and process is alive).
#[derive(Debug)]
pub struct DaemonAlreadyRunning(pub u32);

impl Display for DaemonAlreadyRunning {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Daemon is already running with PID {}", self.0)
    }
}

impl Error for DaemonAlreadyRunning {}
