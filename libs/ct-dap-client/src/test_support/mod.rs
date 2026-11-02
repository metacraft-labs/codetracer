pub mod comparison;
pub mod flow_runner;
pub mod tracepoint_runner;

use std::ffi::OsStr;
use std::path::{Path, PathBuf};

pub use comparison::{
    assert_tracepoint_results_match, parse_trace_output, terminal_events_to_string, ExpectedTrace,
};
pub use flow_runner::{
    BreakpointCheck, CallStackTestConfig, FlowData, FlowTestConfig, FlowTestRunner,
    MultiBreakpointTestConfig, StepAction, SteppingTestConfig,
};
pub use tracepoint_runner::{TracepointSpec, TracepointTestRunner};

type BoxError = Box<dyn std::error::Error + Send + Sync>;

/// Prepare the trace folder for db-backend.
///
/// If `rr_trace_dir`'s parent already contains an `rr` entry pointing to it,
/// use the parent directly. Otherwise create a temporary wrapper directory
/// with an `rr` symlink.
///
/// On Windows, TTD traces are `.run` files (not directories).  When the path
/// points to a `.run` file, pass its parent directory directly — db-backend's
/// `resolve_replay_trace_path` will discover the `.run` file automatically.
pub(crate) fn prepare_trace_folder(
    rr_trace_dir: &Path,
) -> Result<(PathBuf, Option<PathBuf>), BoxError> {
    // Case 0a (Windows TTD): if the path is a .run file, use the parent dir.
    // db-backend discovers .run files by scanning the trace folder.
    if rr_trace_dir.extension().and_then(|e| e.to_str()) == Some("run") && rr_trace_dir.is_file() {
        if let Some(parent) = rr_trace_dir.parent() {
            return Ok((parent.to_path_buf(), None));
        }
    }

    // Case 0b (MCR): if the path is a .ct file, pass it directly as the trace path.
    // db-backend detects .ct files by extension or CTFS magic bytes and routes
    // them to ct-native-replay which spawns ct-mcr debugserver.
    if rr_trace_dir.extension().and_then(|e| e.to_str()) == Some("ct") && rr_trace_dir.is_file() {
        return Ok((rr_trace_dir.to_path_buf(), None));
    }

    // Case 1: parent/rr == rr_trace_dir (uncached layout)
    if let Some(parent) = rr_trace_dir.parent() {
        let rr_child = parent.join("rr");
        if rr_child.exists() && rr_child == rr_trace_dir {
            return Ok((parent.to_path_buf(), None));
        }
    }

    // Case 2: create a wrapper directory with an rr symlink
    let wrapper = std::env::temp_dir()
        .join("codetracer")
        .join("dap-trace-wrappers")
        .join(format!("wrapper_{}", std::process::id()));
    std::fs::create_dir_all(&wrapper)?;
    let rr_link = wrapper.join("rr");
    // Remove stale symlink if present
    let _ = std::fs::remove_file(&rr_link);
    #[cfg(unix)]
    std::os::unix::fs::symlink(rr_trace_dir, &rr_link)?;
    #[cfg(windows)]
    std::os::windows::fs::symlink_dir(rr_trace_dir, &rr_link)?;
    Ok((wrapper.clone(), Some(wrapper)))
}

/// The repository whose build output `ct-native-replay` is.
const NATIVE_BACKEND_REPO: &str = "codetracer-native-backend";

/// Environment variables that name a `ct-native-replay` override, in priority
/// order. db-backend's test harness reads this same list
/// (`src/db-backend/tests/test_harness/mod.rs`, `find_ct_native_replay`), so
/// whichever of them are set, a test replays with the worker the harness
/// recorded with.
pub const CT_NATIVE_REPLAY_OVERRIDE_VARS: &[&str] = &[
    "CT_NATIVE_REPLAY_PATH",
    "CT_RR_SUPPORT_PATH",
    "CT_NATIVE_REPLAY_BIN",
    "CODETRACER_CT_NATIVE_REPLAY_CMD",
];

/// The workspace directory this crate's own checkout sits in, side by side
/// with the `codetracer-native-backend` sibling.
///
/// Taken from this crate's COMPILE-TIME manifest directory
/// (`<workspace>/codetracer/libs/ct-dap-client`), the way db-backend's harness
/// takes it from its own (`sibling_provisioning.rs`, `workspace_root`). The
/// RUNTIME `CARGO_MANIFEST_DIR` cannot be used for this: cargo sets it to the
/// package under test, which for db-backend is `codetracer/src/db-backend`,
/// so its parent is `codetracer/src`, not the workspace.
fn source_workspace_root() -> Option<PathBuf> {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(3)
        .map(Path::to_path_buf)
}

/// Canonicalize `path` for comparing locations, keeping it as given when it
/// cannot be canonicalized (it does not exist).
fn canonical(path: &Path) -> PathBuf {
    path.canonicalize().unwrap_or_else(|_| path.to_path_buf())
}

/// Find the ct-native-replay binary (needed by db-backend as replay-worker).
///
/// Resolves the worker db-backend's test harness resolves (and, when no
/// override names one, has just built), so a test records and replays with
/// one binary. Search order:
/// 1. The override environment variables in [`CT_NATIVE_REPLAY_OVERRIDE_VARS`]
/// 2. The consumer's own `target/debug`, which exists only when the package
///    under test is codetracer-native-backend itself: its tests replay with
///    the build they test, never with another `ct-native-replay` on `PATH`
/// 3. `ct-native-replay` on `PATH`, unless the hit is the workspace sibling's
///    own build (step 4 finds that)
/// 4. The `codetracer-native-backend` sibling of the workspace this crate is
///    checked out in
/// 5. A `codetracer-native-backend` next to the consumer
///
/// Steps 1, 3 and 4 follow the harness's own finder. Step 2 never matches
/// for a db-backend test (`codetracer/src/db-backend/target/debug` holds no
/// `ct-native-replay`), so it does not change what db-backend resolves.
pub(crate) fn find_ct_native_replay() -> Result<PathBuf, BoxError> {
    let overrides = CT_NATIVE_REPLAY_OVERRIDE_VARS
        .iter()
        .filter_map(|var| std::env::var_os(var).map(PathBuf::from));
    let consumer_manifest_dir = std::env::var_os("CARGO_MANIFEST_DIR").map(PathBuf::from);
    resolve_ct_native_replay(
        overrides,
        std::env::var_os("PATH").as_deref(),
        source_workspace_root().as_deref(),
        consumer_manifest_dir.as_deref(),
    )
    .ok_or_else(|| {
        format!(
            "ct-native-replay binary not found (set CT_NATIVE_REPLAY_BIN or build {NATIVE_BACKEND_REPO})"
        )
        .into()
    })
}

/// The search [`find_ct_native_replay`] performs, over explicit inputs so it
/// can be tested against a scratch workspace: the override paths in priority
/// order, the `PATH` value, the workspace whose sibling to use, and the
/// manifest directory of the package under test.
fn resolve_ct_native_replay(
    overrides: impl IntoIterator<Item = PathBuf>,
    path_var: Option<&OsStr>,
    workspace_root: Option<&Path>,
    consumer_manifest_dir: Option<&Path>,
) -> Option<PathBuf> {
    let exe_name = format!("ct-native-replay{}", std::env::consts::EXE_SUFFIX);
    let build_output = |repo_dir: &Path| repo_dir.join("target/debug").join(&exe_name);

    // 1. Explicit overrides, used as given; one naming no file is skipped.
    if let Some(p) = overrides.into_iter().find(|p| p.is_file()) {
        return Some(p);
    }

    // 2. The consumer's own build: codetracer-native-backend testing itself.
    if let Some(own) = consumer_manifest_dir
        .map(build_output)
        .filter(|p| p.is_file())
    {
        return Some(own);
    }

    // 3. PATH, unless the hit lies in the workspace sibling.
    let sibling_dir = workspace_root.map(|ws| ws.join(NATIVE_BACKEND_REPO));
    let in_sibling = |p: &Path| {
        sibling_dir
            .as_deref()
            .is_some_and(|dir| canonical(p).starts_with(canonical(dir)))
    };
    if let Some(hit) = path_var.and_then(|paths| {
        std::env::split_paths(paths)
            .map(|dir| dir.join(&exe_name))
            .find(|p| p.is_file())
    }) {
        if !in_sibling(&hit) {
            return Some(hit);
        }
    }

    // 4. The workspace sibling; 5. a sibling of the consumer.
    let consumer_sibling = consumer_manifest_dir
        .and_then(Path::parent)
        .map(|parent| parent.join(NATIVE_BACKEND_REPO));
    sibling_dir
        .into_iter()
        .chain(consumer_sibling)
        .map(|dir| build_output(&dir))
        .find(|p| p.is_file())
}

#[cfg(test)]
mod tests {
    //! The finder runs against scratch workspaces under the system temp
    //! directory: real directories and files, no mocks.

    use super::*;

    /// A scratch workspace laid out like the real one: a codetracer checkout
    /// with db-backend at `codetracer/src/db-backend`, and a
    /// `codetracer-native-backend` sibling whose debug build exists.
    struct ScratchWorkspace {
        root: PathBuf,
    }

    impl ScratchWorkspace {
        fn new(name: &str) -> Self {
            let root = std::env::temp_dir()
                .join("ct-dap-client-find-native-replay")
                .join(format!("{name}-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&root);
            std::fs::create_dir_all(root.join("codetracer/src/db-backend")).unwrap();
            let ws = ScratchWorkspace { root };
            touch(&ws.sibling_build());
            ws
        }

        fn db_backend_manifest(&self) -> PathBuf {
            self.root.join("codetracer/src/db-backend")
        }

        fn sibling_build(&self) -> PathBuf {
            self.root
                .join(NATIVE_BACKEND_REPO)
                .join("target/debug")
                .join(exe())
        }

        /// Resolve with no override and the given PATH, as a db-backend test
        /// in this workspace would.
        fn resolve_from_db_backend(&self, path_var: Option<&OsStr>) -> Option<PathBuf> {
            resolve_ct_native_replay(
                Vec::new(),
                path_var,
                Some(&self.root),
                Some(&self.db_backend_manifest()),
            )
        }
    }

    impl Drop for ScratchWorkspace {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    fn exe() -> String {
        format!("ct-native-replay{}", std::env::consts::EXE_SUFFIX)
    }

    fn touch(file: &Path) {
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(file, b"").unwrap();
    }

    /// The defect this guards (codetracer-pm issue
    /// `2026-11-01-ct-dap-client-looks-for-the-ct-native-replay-sibling-under-codetracer-src.md`):
    /// for a db-backend test cargo sets `CARGO_MANIFEST_DIR` to
    /// `codetracer/src/db-backend`, and the finder looked for the sibling
    /// next to that, under `codetracer/src`, so it never found the build the
    /// harness had just made.
    #[test]
    fn finds_the_workspace_sibling_from_a_db_backend_test() {
        let ws = ScratchWorkspace::new("db-backend");
        assert_eq!(ws.resolve_from_db_backend(None), Some(ws.sibling_build()));
    }

    /// The real workspace root is the directory that holds this codetracer
    /// checkout, which is where db-backend's harness builds the sibling.
    #[test]
    fn source_workspace_root_is_the_parent_of_this_codetracer_checkout() {
        let manifest = Path::new(env!("CARGO_MANIFEST_DIR"));
        let codetracer = manifest.parent().and_then(Path::parent).unwrap();
        assert!(
            codetracer.join("src/db-backend/Cargo.toml").is_file(),
            "{} is not a codetracer checkout",
            codetracer.display()
        );
        assert_eq!(source_workspace_root().as_deref(), codetracer.parent());
    }

    #[test]
    fn an_override_wins_over_the_sibling_and_a_missing_one_is_skipped() {
        let ws = ScratchWorkspace::new("override");
        let custom = ws.root.join("custom").join(exe());
        touch(&custom);
        let found = resolve_ct_native_replay(
            vec![ws.root.join("missing").join(exe()), custom.clone()],
            None,
            Some(&ws.root),
            Some(&ws.db_backend_manifest()),
        );
        assert_eq!(found, Some(custom));
    }

    /// The harness uses a tool on PATH that is not the sibling's own build as
    /// given, so the runner must replay with that same tool.
    #[test]
    fn a_tool_on_path_outside_the_sibling_wins_over_the_sibling() {
        let ws = ScratchWorkspace::new("path-foreign");
        let installed_dir = ws.root.join("installed/bin");
        touch(&installed_dir.join(exe()));
        let path_var = std::env::join_paths([&installed_dir]).unwrap();
        assert_eq!(
            ws.resolve_from_db_backend(Some(&path_var)),
            Some(installed_dir.join(exe()))
        );
    }

    #[test]
    fn the_sibling_on_path_resolves_to_the_sibling() {
        let ws = ScratchWorkspace::new("path-sibling");
        let path_var = std::env::join_paths([ws.sibling_build().parent().unwrap()]).unwrap();
        assert_eq!(
            ws.resolve_from_db_backend(Some(&path_var)),
            Some(ws.sibling_build())
        );
    }

    /// codetracer-native-backend consumes this crate too; its own tests find
    /// its own build.
    #[test]
    fn the_backend_repo_finds_its_own_build() {
        let ws = ScratchWorkspace::new("backend-itself");
        let backend = ws.root.join(NATIVE_BACKEND_REPO);
        let found = resolve_ct_native_replay(Vec::new(), None, None, Some(&backend));
        assert_eq!(found, Some(ws.sibling_build()));
    }

    /// The backend's tests test the build they sit next to: a different
    /// `ct-native-replay` on `PATH` (an installed CodeTracer, say) must not
    /// replace it, whether or not the backend checkout is the sibling of
    /// this crate's workspace.
    #[test]
    fn the_backend_repo_prefers_its_own_build_to_a_tool_on_path() {
        let ws = ScratchWorkspace::new("backend-vs-path");
        let backend = ws.root.join(NATIVE_BACKEND_REPO);
        let installed_dir = ws.root.join("installed/bin");
        touch(&installed_dir.join(exe()));
        let path_var = std::env::join_paths([&installed_dir]).unwrap();
        for workspace_root in [None, Some(ws.root.join("elsewhere"))] {
            let found = resolve_ct_native_replay(
                Vec::new(),
                Some(&path_var),
                workspace_root.as_deref(),
                Some(&backend),
            );
            assert_eq!(found, Some(ws.sibling_build()));
        }
    }

    #[test]
    fn nothing_built_is_not_found() {
        let ws = ScratchWorkspace::new("nothing");
        std::fs::remove_file(ws.sibling_build()).unwrap();
        assert_eq!(ws.resolve_from_db_backend(None), None);
    }
}
