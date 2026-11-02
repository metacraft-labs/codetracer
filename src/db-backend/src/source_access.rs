//! Where this replay server may read a recording's source text from.
//!
//! A recording names its sources by the paths the recorded program used
//! (`paths.dat`, a step's location). Those paths are recording content: a
//! recording made on another machine, or from other people's traffic, can
//! name any file on the machine that replays it, and place steps on its
//! lines. Every consumer of source text in this server (the line text an
//! origin hop reports, flow's expressions, a location's enclosing function,
//! the DAP `source` request) reads it through an [`crate::expr_loader::ExprLoader`]
//! or through [`SourceAccess`] directly, so this module is where the
//! decision is made.
//!
//! Two places hold the recording's OWN copies of its sources:
//!
//! * the raw source views a container bundles, which
//!   `Handler::load_bundled_sources` extracts to a per-container directory
//!   (the *bundle*);
//! * the trace folder's `files/`, the copies a recorder or `ct` import
//!   writes beside the container.
//!
//! The recorded path itself, read where it points on this host, is the
//! host's file, not the recording's. With [`HostSourceReads::Refused`] it is
//! never opened, read or stat'ed: source text comes from the two copies
//! above (and from the in-memory VFS a browser host fills from the
//! recording) or not at all. With [`HostSourceReads::Allowed`], the default
//! for a client that does not say, the recorded path is read as well, which
//! is what a developer replaying their own recording in the desktop GUI
//! expects.
//!
//! The setting arrives as the DAP `launch` argument `hostSourceReads`; the
//! CodeTracer daemon always sends it, from the host-read setting of the
//! client that opened the trace (`trace mcp --allow-host-source-reads`).
//!
//! A copy is opened beneath its root one component at a time without
//! following a symlink ([`ct_open_beneath::open_beneath`]), the same rule the
//! MCP server's `read_source_file` applies to `files/`: the layout under
//! either root came from the recording, so a symlink planted there must not
//! turn "the recording's copy" into a host file.

use std::path::{Component, Path, PathBuf};
use std::sync::{Arc, RwLock};

use crate::expr_loader::{bundle_path_components, resolve_dot_segments, strip_godot_scheme, vfs_source_text};

/// Whether a recorded source path may be read at its location on this host.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum HostSourceReads {
    /// The recorded path is read when the recording carries no copy (the
    /// default, and the behaviour before the setting existed).
    #[default]
    Allowed,
    /// Only the recording's own copies are read.
    Refused,
}

impl HostSourceReads {
    /// The setting a `launch` request's `hostSourceReads` argument names:
    /// `false` refuses host reads; `true` or no value allows them.
    pub fn from_launch_argument(value: Option<bool>) -> Self {
        match value {
            Some(false) => Self::Refused,
            _ => Self::Allowed,
        }
    }

    /// Whether host reads are allowed.
    pub fn is_allowed(self) -> bool {
        self == Self::Allowed
    }
}

/// The message every refusal to read a recorded path from the host carries,
/// so a client can tell "the recording carries no copy and host reads are
/// off" from a missing file.
pub const HOST_READS_REFUSED: &str = "the recording carries no copy of this source, and this session does not read \
     sources from the replay host (host source reads are off)";

/// The source-reading rule for one replay session: the host-read setting and
/// the two roots that hold the recording's own copies.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SourceAccess {
    /// Whether a recorded path may be read where it points on this host.
    pub host_reads: HostSourceReads,
    /// The trace folder's `files/` directory, when the trace has a folder.
    pub files_root: Option<PathBuf>,
    /// The directory the container's bundled raw source views were
    /// extracted to, once they have been.
    pub bundled_root: Option<PathBuf>,
}

impl SourceAccess {
    /// Whether a recorded path may be read at its location on this host.
    pub fn host_reads_allowed(&self) -> bool {
        self.host_reads.is_allowed()
    }

    /// The text of the recording's own copy of `recorded`: the bundle first
    /// (the container's own bytes), then `files/`, then the in-memory VFS.
    /// `None` when the recording carries no copy. Never reads `recorded`
    /// where it points on this host.
    pub fn read_recording_copy(&self, recorded: &Path) -> Option<String> {
        for root in [self.bundled_root.as_deref(), self.files_root.as_deref()]
            .into_iter()
            .flatten()
        {
            if let Some(text) = read_beneath(root, recorded) {
                return Some(text);
            }
        }
        vfs_source_text(recorded)
    }

    /// Whether the recording carries a copy of `recorded` (see
    /// [`Self::read_recording_copy`]).
    pub fn has_recording_copy(&self, recorded: &Path) -> bool {
        self.read_recording_copy(recorded).is_some()
    }
}

/// A [`SourceAccess`] shared by every loader of one replay session.
///
/// A session's handler, its flow preloader and its replay session each hold
/// source loaders, created at different times; the bundle root is only
/// known after the container's views are extracted. Sharing one cell means
/// every loader sees the session's rule as it is now, and none can be left
/// on a default that reads the host.
#[derive(Clone, Debug, Default)]
pub struct SourceAccessHandle(Arc<RwLock<SourceAccess>>);

impl SourceAccessHandle {
    /// A handle holding `access`.
    pub fn new(access: SourceAccess) -> Self {
        Self(Arc::new(RwLock::new(access)))
    }

    /// The rule as it is now. A poisoned lock still holds a valid value (a
    /// writer only ever assigns fields), so it is read through.
    pub fn get(&self) -> SourceAccess {
        match self.0.read() {
            Ok(guard) => guard.clone(),
            Err(poisoned) => poisoned.into_inner().clone(),
        }
    }

    /// Records the trace folder's `files/` directory.
    pub fn set_files_root(&self, root: Option<PathBuf>) {
        match self.0.write() {
            Ok(mut guard) => guard.files_root = root,
            Err(poisoned) => poisoned.into_inner().files_root = root,
        }
    }

    /// Records where the container's bundled sources were extracted.
    pub fn set_bundled_root(&self, root: Option<PathBuf>) {
        match self.0.write() {
            Ok(mut guard) => guard.bundled_root = root,
            Err(poisoned) => poisoned.into_inner().bundled_root = root,
        }
    }
}

/// The paths, relative to a copy root, under which a recording may hold its
/// copy of `recorded`, most specific first.
///
/// The writer's exact mapping comes first: the path with its root (and a
/// Godot `res://` / `user://` scheme) stripped, as `ct` writes `files/` and
/// the bundle extraction writes the bundle
/// ([`crate::expr_loader::bundled_source_path`], generation 0). Then every
/// suffix of the path, longest first, because some recorders write
/// project-relative copies (`files/src/main.nr`) for paths they report as
/// absolute; [`crate::expr_loader::resolve_bundled_source`] walks the same
/// suffixes. `.` and `..` are resolved first ([`resolve_dot_segments`]), and
/// a candidate that still holds `..` (a path climbing out of its root) is
/// skipped.
pub fn copy_candidates(recorded: &Path) -> Vec<PathBuf> {
    let resolved = resolve_dot_segments(&recorded.to_string_lossy());
    let relative: &str = strip_godot_scheme(&resolved).unwrap_or(&resolved);
    let mut candidates: Vec<PathBuf> = Vec::new();

    let exact: PathBuf = Path::new(relative)
        .components()
        .filter(|c| !matches!(c, Component::Prefix(_) | Component::RootDir | Component::CurDir))
        .collect();
    if !exact.as_os_str().is_empty() && exact.components().all(|c| matches!(c, Component::Normal(_))) {
        candidates.push(exact);
    }

    let components = bundle_path_components(relative);
    for start in 0..components.len() {
        let suffix = &components[start..];
        if suffix.contains(&"..") {
            continue;
        }
        let candidate: PathBuf = suffix.iter().collect();
        if !candidates.contains(&candidate) {
            candidates.push(candidate);
        }
    }
    candidates
}

/// The text of the first of `recorded`'s [`copy_candidates`] that is a
/// regular file beneath `root`, opened without following a symlink below
/// `root`; for a root that is a VFS key prefix (a browser session), the VFS
/// entry at the same place.
pub fn read_beneath(root: &Path, recorded: &Path) -> Option<String> {
    copy_candidates(recorded)
        .into_iter()
        .find_map(|relative| read_relative_beneath(root, &relative))
}

/// The text of `candidate`, a path under `root` that a caller derived from a
/// recorded path, opened beneath `root` without following a symlink below it
/// (or, failing that, the VFS entry at `candidate`). `None` when `candidate`
/// is not under `root` with only normal components.
pub fn read_contained(root: &Path, candidate: &Path) -> Option<String> {
    let relative = candidate.strip_prefix(root).ok()?;
    if !relative.components().all(|c| matches!(c, Component::Normal(_))) {
        return None;
    }
    read_relative_beneath(root, relative)
}

fn read_relative_beneath(root: &Path, relative: &Path) -> Option<String> {
    match ct_open_beneath::read_to_string_beneath(root, relative) {
        Ok(text) => Some(text),
        // No filesystem (a browser session): the VFS holds the copy the host
        // pushed in at the same place. The VFS is this process's memory, so
        // there is nothing to follow.
        Err(_) => vfs_source_text(&root.join(relative)),
    }
}

#[cfg(all(test, unix))]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::symlink;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("ct-source-access-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn candidates_are_the_exact_mapping_then_suffixes_longest_first() {
        let candidates = copy_candidates(Path::new("/home/u/project/src/app.py"));
        assert_eq!(
            candidates,
            vec![
                PathBuf::from("home/u/project/src/app.py"),
                PathBuf::from("u/project/src/app.py"),
                PathBuf::from("project/src/app.py"),
                PathBuf::from("src/app.py"),
                PathBuf::from("app.py"),
            ]
        );
        // `..` folded first; one climbing out of the root is never a candidate.
        assert_eq!(copy_candidates(Path::new("/a/../b.py"))[0], PathBuf::from("b.py"));
        assert!(
            copy_candidates(Path::new("../../etc/passwd"))
                .iter()
                .all(|c| c.components().all(|x| matches!(x, Component::Normal(_)))),
        );
        assert_eq!(
            copy_candidates(Path::new("res://scene.gd")),
            vec![PathBuf::from("scene.gd")]
        );
    }

    #[test]
    fn refused_reads_only_the_recordings_copies() {
        let dir = scratch("refused");
        let host = dir.join("host/secret.py");
        fs::create_dir_all(host.parent().unwrap()).unwrap();
        fs::write(&host, "host only\n").unwrap();
        let listed = dir.join("project/app.py");
        fs::create_dir_all(listed.parent().unwrap()).unwrap();
        fs::write(&listed, "host copy of app\n").unwrap();
        let files = dir.join("trace/files");
        let copy = files.join(listed.strip_prefix("/").unwrap());
        fs::create_dir_all(copy.parent().unwrap()).unwrap();
        fs::write(&copy, "recording copy of app\n").unwrap();

        let access = SourceAccess {
            host_reads: HostSourceReads::Refused,
            files_root: Some(files.clone()),
            bundled_root: None,
        };
        assert_eq!(
            access.read_recording_copy(&listed).as_deref(),
            Some("recording copy of app\n")
        );
        assert_eq!(access.read_recording_copy(&host), None);
        assert!(!access.has_recording_copy(&host));

        // A symlink in `files/` that points at the host file is not a copy.
        let planted = files.join(host.strip_prefix("/").unwrap());
        fs::create_dir_all(planted.parent().unwrap()).unwrap();
        symlink(&host, &planted).unwrap();
        assert_eq!(fs::read_to_string(&planted).unwrap(), "host only\n");
        assert_eq!(access.read_recording_copy(&host), None);
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn the_bundle_wins_over_files() {
        let dir = scratch("bundle");
        let recorded = Path::new("/w/src/main.nr");
        for (root, text) in [("bundle", "bundled\n"), ("files", "files copy\n")] {
            let at = dir.join(root).join("w/src/main.nr");
            fs::create_dir_all(at.parent().unwrap()).unwrap();
            fs::write(&at, text).unwrap();
        }
        let access = SourceAccess {
            host_reads: HostSourceReads::Refused,
            files_root: Some(dir.join("files")),
            bundled_root: Some(dir.join("bundle")),
        };
        assert_eq!(access.read_recording_copy(recorded).as_deref(), Some("bundled\n"));
        fs::remove_dir_all(&dir).unwrap();
    }

    /// A loader under a session with host reads off serves a listed file
    /// from the recording's copy, refuses one it has no copy of with the
    /// reason, reports it missing, and never hashes the host file; the same
    /// loader with host reads on reads the host file.
    #[test]
    fn a_loader_with_host_reads_off_reads_only_the_recordings_copies() {
        use crate::expr_loader::{ExprLoader, SourceOrigin};
        use crate::task::{CoreTrace, Location};
        let dir = scratch("loader");
        let host = dir.join("host/secret.py");
        fs::create_dir_all(host.parent().unwrap()).unwrap();
        fs::write(&host, "x = 1  # host\n").unwrap();
        let copied = dir.join("project/app.py");
        fs::create_dir_all(copied.parent().unwrap()).unwrap();
        fs::write(&copied, "y = 2  # host copy\n").unwrap();
        let files = dir.join("trace/files");
        let copy = files.join(copied.strip_prefix("/").unwrap());
        fs::create_dir_all(copy.parent().unwrap()).unwrap();
        fs::write(&copy, "y = 2  # recording\n").unwrap();

        let refused = SourceAccessHandle::new(SourceAccess {
            host_reads: HostSourceReads::Refused,
            files_root: Some(files.clone()),
            bundled_root: None,
        });
        let mut loader = ExprLoader::with_source_access(CoreTrace::default(), refused);
        let err = loader.file_source_code(&host).unwrap_err().to_string();
        assert!(err.contains("host source reads are off"), "{err}");
        assert_eq!(loader.file_source_code(&copied).unwrap(), "y = 2  # recording\n");
        let (line, origin) = loader.get_source_line_v2(&host, 1, None, 0);
        assert_eq!((line.as_str(), origin), ("", SourceOrigin::Unavailable));
        let (line, _) = loader.get_source_line_v2(&copied, 1, None, 0);
        assert_eq!(line, "y = 2  # recording");
        assert_eq!(
            loader.source_digest_bytes(&copied, SourceOrigin::Filesystem, None),
            Some(b"y = 2  # recording\n".to_vec())
        );
        assert_eq!(loader.source_digest_bytes(&host, SourceOrigin::Unavailable, None), None);
        let host_str = host.to_str().unwrap();
        assert_eq!(
            loader.source_probe_path(Path::new("/w"), host_str),
            PathBuf::from(host_str)
        );
        let location = Location {
            path: host_str.to_string(),
            line: 1,
            ..Location::default()
        };
        assert!(
            loader
                .find_function_location(&location, &codetracer_trace_types::Line(1))
                .missing_path
        );

        let mut allowed = ExprLoader::new(CoreTrace::default());
        assert_eq!(allowed.file_source_code(&host).unwrap(), "x = 1  # host\n");
        let (line, origin) = allowed.get_source_line_v2(&host, 1, None, 0);
        assert_eq!((line.as_str(), origin), ("x = 1  # host", SourceOrigin::Filesystem));
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn launch_argument_false_is_the_only_refusal() {
        assert_eq!(
            HostSourceReads::from_launch_argument(Some(false)),
            HostSourceReads::Refused
        );
        assert_eq!(
            HostSourceReads::from_launch_argument(Some(true)),
            HostSourceReads::Allowed
        );
        assert_eq!(HostSourceReads::from_launch_argument(None), HostSourceReads::Allowed);
    }
}
