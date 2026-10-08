//! A recording that fails part-way leaves no scratch directory behind.
//!
//! `TestRecording::create_mcr` builds and records into a fresh directory under
//! the temp dir, which the recording's `Drop` removes. When the build or the
//! recording fails there is no recording to drop, so the directory has to be
//! removed on the error path itself -- otherwise every failing MCR flow test
//! (the Go arm, while the recorder refuses Go) leaves one behind per run.
//!
//! `/bin/false` stands in for `ct-native-replay` (justified: the property is
//! about the harness's error path, which needs a build step that fails
//! deterministically; the real tool cannot be made to fail on demand).

mod test_harness;
use std::path::{Path, PathBuf};

use test_harness::{Language, TestRecording};

#[test]
fn a_failed_mcr_build_removes_its_scratch_directory() {
    let source = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("test-programs/c/c_flow_test.c");
    let failure = TestRecording::create_mcr(&source, Language::C, "cleanup", Path::new("/bin/false"));
    assert!(failure.is_err(), "a build step that fails must fail the recording");

    let scratch = std::env::temp_dir().join(format!("mcr_flow_test_c_cleanup_{}", std::process::id()));
    assert!(
        !scratch.exists(),
        "the failed recording left its scratch directory behind: {}",
        scratch.display()
    );
}
