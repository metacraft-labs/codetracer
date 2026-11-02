//! A recording that fails part-way leaves no scratch directory behind.
//!
//! `TestRecording::create_mcr` builds and records into a fresh directory under
//! the temp dir, which the recording's `Drop` removes. When the build or the
//! recording fails there is no recording to drop, so the directory has to be
//! removed on the error path itself -- otherwise every failing MCR flow test
//! (the Go arm, while the recorder refuses Go) leaves one behind per run.
//!
//! `false(1)` stands in for `ct-native-replay` (justified: the property is
//! about the harness's error path, which needs a build step that fails
//! deterministically; the real tool cannot be made to fail on demand).
//!
//! Unix only: Windows has no `false(1)`. Before it was looked up, the test
//! spawned `/bin/false` everywhere, and where that path does not exist (Windows,
//! NixOS) the spawn failed and the test passed without running a build step.
#![cfg(unix)]

mod test_harness;
use std::path::{Path, PathBuf};

use test_harness::{Language, TestRecording};

#[test]
fn a_failed_mcr_build_removes_its_scratch_directory() {
    let source = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("test-programs/c/c_flow_test.c");
    let failure = TestRecording::create_mcr(&source, Language::C, "cleanup", &false_utility());
    let error = match failure {
        Ok(_) => panic!("a build step that fails must fail the recording"),
        Err(error) => error,
    };
    // The build step must have RUN and failed. A tool that could not be
    // spawned fails too, but that is not the error path this test is about.
    assert!(
        error.starts_with("MCR build failed"),
        "the recording failed for a reason other than the failing build step: {error}"
    );

    // `create_mcr` names its directory `mcr_flow_test_c_cleanup_<pid>_<seq>`;
    // the sequence number is private to the harness, so look for any
    // directory of this process with that prefix.
    let prefix = format!("mcr_flow_test_c_cleanup_{}_", std::process::id());
    let leftovers: Vec<PathBuf> = std::fs::read_dir(std::env::temp_dir())
        .expect("the temp dir is readable")
        .filter_map(|entry| entry.ok())
        .filter(|entry| entry.file_name().to_string_lossy().starts_with(&prefix))
        .map(|entry| entry.path())
        .collect();
    assert!(
        leftovers.is_empty(),
        "the failed recording left its scratch directory behind: {leftovers:?}"
    );
}

/// The `false(1)` utility, found as a shell finds it: the first executable
/// `false` in the absolute directories of `PATH`, then `/usr/bin/false` and
/// `/bin/false`. POSIX specifies the utility, not where it is installed:
/// NixOS has neither of those two paths and puts `false` on `PATH` from the
/// Nix store. (The same lookup as `false_utility` in
/// src/backend-manager/tests/start_replay_failure_test.rs.)
fn false_utility() -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let on_path = std::env::var_os("PATH")
        .map(|path| std::env::split_paths(&path).collect::<Vec<_>>())
        .unwrap_or_default();
    on_path
        .into_iter()
        // A relative entry would be resolved against the working directory.
        .filter(|dir| dir.is_absolute())
        .map(|dir| dir.join("false"))
        .chain([
            Path::new("/usr/bin/false").to_path_buf(),
            Path::new("/bin/false").to_path_buf(),
        ])
        .find(|candidate| {
            std::fs::metadata(candidate)
                .map(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
                .unwrap_or(false)
        })
        .expect("false(1): no executable `false` on PATH, at /usr/bin/false or at /bin/false")
}
