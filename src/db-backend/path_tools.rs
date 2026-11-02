//! Resolve declared executables without Windows' implicit system-directory search.
use std::{
    env,
    ffi::OsStr,
    path::{Path, PathBuf},
    process::Command,
};

/// Return the first existing PATH candidate as an absolute path. Empty and
/// relative entries retain their normal current-directory meaning and ordering.
pub fn executable_on_path(name: &str, path: &OsStr, cwd: &Path) -> Option<PathBuf> {
    for dir in env::split_paths(path) {
        let candidate = if dir.is_absolute() {
            dir.join(name)
        } else {
            cwd.join(dir).join(name)
        };
        // Windows also permits drive-relative entries such as C:tools.
        // Resolve those through the platform API before exposing an image to
        // Command, without canonicalizing symlinks or changing PATH order.
        let candidate = std::path::absolute(candidate).ok()?;
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

pub fn which_on_path(name: &str) -> Option<PathBuf> {
    executable_on_path(name, &env::var_os("PATH")?, &env::current_dir().ok()?)
}

/// An explicit executable prevents Rust/Windows from preferring System32 over
/// the inherited activated PATH. POSIX keeps its existing shell lookup.
pub fn bash_command() -> Command {
    #[cfg(windows)]
    {
        Command::new(which_on_path("bash.exe").expect("declared bash.exe is missing from activated PATH"))
    }
    #[cfg(not(windows))]
    {
        Command::new("bash")
    }
}
