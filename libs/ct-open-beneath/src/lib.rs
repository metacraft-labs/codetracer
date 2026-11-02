//! Open a file a recording carries, beneath the directory that holds it,
//! without following a symlink anywhere below that directory.
//!
//! A recording's own copies of its sources (a trace folder's `files/`, the
//! raw source views a replay server extracts from a container) sit in a
//! directory tree whose layout came from the recording, not from this
//! process.  A path joined onto that directory and handed to `File::open`
//! resolves every symlink on the way, so one planted anywhere below the root
//! (or swapped in after a check) reads a file outside the recording while the
//! caller believes it is reading the recording's copy.  [`open_beneath`] is
//! the one opening rule both CodeTracer read sides use for such files.

use std::fs::File;
use std::io::{self, Read};
use std::path::{Component, Path};

/// Opens the regular file `relative` beneath the directory `root` without
/// following a symlink in any component of `relative`.
///
/// On Unix each component is opened with `openat(2)` relative to the
/// directory opened before it, with `O_NOFOLLOW` (and `O_DIRECTORY` for the
/// directories), so the walk never leaves `root` and a symlink, whether
/// present when the walk starts or swapped in during it, fails the open
/// (`ELOOP`/`ENOTDIR`) instead of being followed
/// (<https://man7.org/linux/man-pages/man2/open.2.html>, `O_NOFOLLOW`). The
/// last component is opened `O_NONBLOCK` so a FIFO cannot stall the caller,
/// and anything but a regular file is refused after the open. `root` itself
/// is trusted as given.  `relative` must consist of normal components only.
///
/// Elsewhere every component is checked with `symlink_metadata` before the
/// open, which refuses a symlink present at the check but not one swapped in
/// between the check and the open.
pub fn open_beneath(root: &Path, relative: &Path) -> io::Result<File> {
    let mut names = Vec::new();
    for component in relative.components() {
        match component {
            Component::Normal(name) => names.push(name),
            _ => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "only normal path components are opened beneath the root",
                ));
            }
        }
    }
    if names.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "no file named beneath the root",
        ));
    }

    #[cfg(unix)]
    let file = {
        use std::ffi::CString;
        use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
        use std::os::unix::ffi::OsStrExt;
        let to_c = |bytes: &[u8]| {
            CString::new(bytes)
                .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "a NUL in a path"))
        };
        let root_c = to_c(root.as_os_str().as_bytes())?;
        // SAFETY: `root_c` is a valid NUL-terminated string; the returned
        // descriptor is checked and then owned by `OwnedFd`.
        let fd = unsafe {
            libc::open(
                root_c.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: `fd` is a freshly opened descriptor nothing else owns.
        let mut current = unsafe { OwnedFd::from_raw_fd(fd) };
        for (index, name) in names.iter().enumerate() {
            let last = index + 1 == names.len();
            let name_c = to_c(name.as_bytes())?;
            let flags = libc::O_RDONLY
                | libc::O_CLOEXEC
                | libc::O_NOFOLLOW
                | if last {
                    libc::O_NONBLOCK
                } else {
                    libc::O_DIRECTORY
                };
            // SAFETY: `current` is an open directory descriptor and
            // `name_c` a valid NUL-terminated single component.
            let fd = unsafe { libc::openat(current.as_raw_fd(), name_c.as_ptr(), flags) };
            if fd < 0 {
                return Err(io::Error::last_os_error());
            }
            // SAFETY: as above.
            current = unsafe { OwnedFd::from_raw_fd(fd) };
        }
        File::from(current)
    };

    #[cfg(not(unix))]
    let file = {
        let mut path = root.to_path_buf();
        for name in &names {
            path.push(name);
            if std::fs::symlink_metadata(&path)?.file_type().is_symlink() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "a symlink beneath the root is not followed",
                ));
            }
        }
        File::open(&path)?
    };

    if !file.metadata()?.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "not a regular file",
        ));
    }
    Ok(file)
}

/// [`open_beneath`], then the whole file as UTF-8 text.
pub fn read_to_string_beneath(root: &Path, relative: &Path) -> io::Result<String> {
    let mut content = String::new();
    open_beneath(root, relative)?.read_to_string(&mut content)?;
    Ok(content)
}

#[cfg(all(test, unix))]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::symlink;
    use std::path::PathBuf;

    /// A fresh directory under the target's temporary directory, removed by
    /// the caller's `fs::remove_dir_all` at the end of the test.
    fn scratch(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("ct-open-beneath-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn reads_a_regular_file_beneath_the_root() {
        let dir = scratch("regular");
        fs::create_dir_all(dir.join("root/src")).unwrap();
        fs::write(dir.join("root/src/app.py"), "copy\n").unwrap();
        let text = read_to_string_beneath(&dir.join("root"), Path::new("src/app.py")).unwrap();
        assert_eq!(text, "copy\n");
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn refuses_a_symlink_in_any_component() {
        let dir = scratch("symlink");
        fs::create_dir_all(dir.join("root/src")).unwrap();
        fs::create_dir_all(dir.join("outside")).unwrap();
        fs::write(dir.join("outside/secret"), "host\n").unwrap();
        // A symlinked file, a symlinked directory, and a symlink that stays
        // inside the root: each is refused, wherever it points.
        symlink(dir.join("outside/secret"), dir.join("root/src/file")).unwrap();
        symlink(dir.join("outside"), dir.join("root/dir")).unwrap();
        fs::write(dir.join("root/src/real"), "copy\n").unwrap();
        symlink(dir.join("root/src/real"), dir.join("root/src/inside")).unwrap();
        for relative in ["src/file", "dir/secret", "src/inside"] {
            assert!(
                open_beneath(&dir.join("root"), Path::new(relative)).is_err(),
                "{relative} was opened through a symlink"
            );
        }
        // The same files are reachable by a plain open, so the refusals are
        // the rule, not missing files.
        assert_eq!(
            fs::read_to_string(dir.join("root/dir/secret")).unwrap(),
            "host\n"
        );
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn refuses_non_normal_components_and_non_files() {
        let dir = scratch("components");
        fs::create_dir_all(dir.join("root/src")).unwrap();
        fs::write(dir.join("secret"), "host\n").unwrap();
        for relative in ["../secret", "/secret", "./src", "", "src"] {
            assert!(
                open_beneath(&dir.join("root"), Path::new(relative)).is_err(),
                "{relative:?} was opened"
            );
        }
        fs::remove_dir_all(&dir).unwrap();
    }
}
