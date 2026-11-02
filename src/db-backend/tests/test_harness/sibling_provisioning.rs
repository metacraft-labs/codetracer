//! Provisioning workspace siblings for integration tests.
//!
//! Shared by two test crates: db-backend's harness declares it as a submodule
//! (`test_harness/mod.rs`), and backend-manager's integration tests include it
//! with `#[path]` (`src/backend-manager/tests/real_recording_integration.rs`),
//! so both crates build a missing or stale sibling the same way, through
//! `scripts/build-siblings.sh`, under the same cross-process lock. It uses
//! only the standard library, so either crate can compile it.
//!
//! Many suites drive a recorder or tool that lives in a SIBLING checkout
//! of the workspace (codetracer-beam-recorder, codetracer-js-recorder,
//! codetracer-native-backend, …). A plain `cargo test` used to look for the
//! sibling's build output and, when nobody had built it, fail with "binary not
//! found": 30-odd failures on a fresh workspace, every one of them a missing
//! build step rather than a defect (codetracer-pm issues/2026-10-22-db-backend-
//! cargo-test-has-33-baseline-failures-on-agents.md). The rule is that the test
//! stays loud and the prerequisite is SUPPLIED, never skipped (codetracer-pm
//! spec/Testing/Silent-Self-Pass-Audit-2026-08-23.md). So the finders
//! supply it: when no explicit override names a tool, they build the workspace
//! sibling with `scripts/build-siblings.sh --only <key>`, the one script that
//! knows how to build each sibling in its own pinned dev shell, and return the
//! artifact it produced.
//!
//! build-siblings.sh reuses an artifact only when its build stamp matches the
//! sibling's current inputs, so asking it every time is how a STALE build gets
//! rebuilt as well as a missing one; for a current one it is a stamp check.
//!
//! An explicit override (each finder's environment variable, or a tool on PATH
//! that is not the sibling's own output) is used as given and never built:
//! whoever set it chose that tool.

#![allow(dead_code)]

// Relative to this file's directory (`src/db-backend/tests/test_harness/`),
// whichever crate includes it.
#[path = "../../path_tools.rs"]
mod path_tools;
pub use path_tools::bash_command;

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Stdio;

/// Canonicalize a path, stripping the Windows `\\?\` UNC prefix if present.
///
/// Rust's `std::fs::canonicalize` on Windows returns extended-length paths
/// prefixed with `\\?\` (e.g. `\\?\D:\foo\bar`). Many tools (Node.js, Ruby)
/// cannot handle this prefix and fail with confusing errors like
/// `EISDIR: illegal operation on a directory, lstat 'D:'`.
///
/// This helper strips the prefix so callers get a normal absolute path.
pub fn safe_canonicalize(path: &Path) -> PathBuf {
    match path.canonicalize() {
        Ok(p) => {
            #[cfg(windows)]
            {
                let s = p.to_string_lossy();
                if let Some(stripped) = s.strip_prefix(r"\\?\") {
                    return PathBuf::from(stripped);
                }
            }
            p
        }
        Err(_) => path.to_path_buf(),
    }
}

/// The codetracer checkout this test binary was built from.
pub fn codetracer_root() -> PathBuf {
    safe_canonicalize(&PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../.."))
}

/// The workspace directory the sibling repositories are checked out in, side
/// by side with codetracer.
pub fn workspace_root() -> PathBuf {
    let root = codetracer_root();
    root.parent()
        .unwrap_or_else(|| panic!("the codetracer checkout {} has no parent directory", root.display()))
        .to_path_buf()
}

/// Whether `path` lies inside the workspace sibling checkout `repo`.
///
/// A finder treats such a hit (typically on the `PATH` the dev shell assembled
/// from the sibling's build output) as the sibling itself and provisions it,
/// instead of using it as found: the hit says only that the sibling was built
/// at some point, not that the build is current. For the Ruby recorder it says
/// even less, because the wrapper on PATH is checked in and the extension it
/// loads may never have been built (measured 2026-10-24: the dev shell's PATH
/// carried the wrapper while the extension was absent).
pub fn is_in_workspace_sibling(path: &Path, repo: &str) -> bool {
    safe_canonicalize(path).starts_with(workspace_root().join(repo))
}

/// Run `produce` at most once per test process for `key`, and return what it
/// produced; panic with its diagnostic when it failed.
///
/// Two locks serialise the work:
///
/// - an in-process mutex, held across `produce`, so the tests of one binary
///   (which libtest runs on parallel threads) start one build and wait for it,
///   instead of starting N identical ones; and an outcome cached per key, so
///   the rest of the binary neither repeats a build nor retries a failed one;
/// - an exclusive file lock (`flock(2)` on Unix, `LockFileEx` on Windows, via
///   `File::lock`) on `.tools/test-harness-provisioning.lock` in the codetracer
///   checkout, held for the same span, so test binaries that run concurrently
///   (cargo runs them one after another, nextest in parallel) never build the
///   same sibling at once. One lock for every key rather than one per key:
///   the cross-process recording tools include the JS recorder, which also has
///   a key of its own, and serialising all provisioning is simpler than
///   proving which keys share builds. Every build is CPU-bound, so running two
///   at once would not finish sooner anyway.
///
/// There is no timeout on either lock: a build that takes long is waited for,
/// and one that hangs is a defect to see, not to paper over.
pub fn provision_once(key: &str, produce: impl FnOnce() -> Result<PathBuf, String>) -> PathBuf {
    use std::sync::{Mutex, OnceLock};

    static OUTCOMES: OnceLock<Mutex<HashMap<String, Result<PathBuf, String>>>> = OnceLock::new();
    let outcomes = OUTCOMES.get_or_init(|| Mutex::new(HashMap::new()));
    // A test that panicked while holding the guard poisons the mutex; the map
    // it guards is still consistent (an entry is inserted whole or not at
    // all), so carry on with it.
    let mut guard = outcomes.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let outcome = match guard.get(key) {
        Some(outcome) => outcome.clone(),
        None => {
            let outcome = with_provisioning_file_lock(produce);
            guard.insert(key.to_string(), outcome.clone());
            outcome
        }
    };
    drop(guard);
    outcome.unwrap_or_else(|diagnostic| panic!("{diagnostic}"))
}

/// Hold the cross-process provisioning lock (see [`provision_once`]) while
/// `produce` runs. The lock is released when the file is closed, which also
/// happens if this process dies, so a killed test cannot leave it held.
fn with_provisioning_file_lock(produce: impl FnOnce() -> Result<PathBuf, String>) -> Result<PathBuf, String> {
    let lock_dir = codetracer_root().join(".tools");
    fs::create_dir_all(&lock_dir).map_err(|e| {
        format!(
            "cannot create the provisioning lock directory {}: {e}",
            lock_dir.display()
        )
    })?;
    let lock_path = lock_dir.join("test-harness-provisioning.lock");
    let lock_file = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(&lock_path)
        .map_err(|e| format!("cannot open the provisioning lock {}: {e}", lock_path.display()))?;
    lock_file
        .lock()
        .map_err(|e| format!("cannot take the provisioning lock {}: {e}", lock_path.display()))?;
    produce()
}

/// Build the workspace sibling artifact `artifact` (relative to the sibling
/// checkout `repo`) with `scripts/build-siblings.sh --only <key>`, and return
/// its absolute path.
///
/// `key` is that script's logical key for the artifact, and `artifact` the
/// path its entry names, so the script and the harness agree on what "built"
/// means. `--only` matches keys by SUBSTRING, so a key must be one that no
/// other entry's key contains; every key the finders pass is. A key the script
/// does not know builds nothing, and is caught by the artifact check below.
///
/// Panics, naming the sibling and the remedy, when the sibling is not checked
/// out, when the build fails (build-siblings.sh prints the tail of the failing
/// build's log, and its output is inherited, so it is right above the panic),
/// or when the build reports success without producing the artifact. The
/// script itself treats a missing checkout as MISSING and exits 0, which is
/// why the checkout and the artifact are checked here.
pub fn provision_sibling(key: &str, repo: &str, artifact: &str) -> PathBuf {
    provision_once(&format!("build-siblings:{key}"), || {
        let repo_dir = workspace_root().join(repo);
        if !repo_dir.is_dir() {
            return Err(format!(
                "MISSING PREREQUISITE: the `{repo}` sibling repository is not checked out at {}, so \
                 `{artifact}` cannot be built for this test. Check it out (`repro ws enable codetracer` \
                 checks out every repository the codetracer project includes), or point this test at a \
                 build through the override its finder documents.",
                repo_dir.display()
            ));
        }
        let script = codetracer_root().join("scripts/build-siblings.sh");
        eprintln!(
            "[test_harness] provisioning `{key}`: bash {} --only {key}",
            script.display()
        );
        // Both streams inherited: a first build takes minutes, and the
        // script's progress and summary are the only sign the test has not
        // hung, and the only place a failure's cause is printed.
        let status = bash_command()
            .arg(&script)
            .arg("--only")
            .arg(key)
            .current_dir(codetracer_root())
            .stdin(Stdio::null())
            .status()
            .map_err(|e| format!("could not run {}: {e}", script.display()))?;
        if !status.success() {
            return Err(format!(
                "could not build `{key}` ({artifact} in {}): `bash {} --only {key}` exited with {status}. \
                 Its summary above names the failing build and the tail of its log.",
                repo_dir.display(),
                script.display()
            ));
        }
        let artifact_path = repo_dir.join(artifact);
        if !artifact_path.exists() {
            return Err(format!(
                "`bash {} --only {key}` succeeded but {} does not exist; the script's entry for `{key}` \
                 and this harness disagree about the artifact (or `{key}` is not one of its keys).",
                script.display(),
                artifact_path.display()
            ));
        }
        Ok(safe_canonicalize(&artifact_path))
    })
}
