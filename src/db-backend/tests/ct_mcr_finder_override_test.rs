//! The test harness's `ct-mcr` finder (`test_harness::find_ct_mcr`) honours
//! the override names `ct` reads, in `ct`'s order (codetracer-pm
//! `spec/Testing/Test-Program-Layout.md`, "Provisioning the Recorder a
//! Recording Needs"): `CODETRACER_CT_MCR_CMD`, then `CODETRACER_CT_MCR_PATH`.
//! A named tool outside the `codetracer-native-recorder` sibling is used as
//! given and never built.
//!
//! The finder used to read only `CODETRACER_CT_MCR_CMD`. A developer who set
//! only `CODETRACER_CT_MCR_PATH` (the name `ct`'s own install hint gives) got
//! the sibling provisioned instead, exported as `CODETRACER_CT_MCR_CMD`,
//! which `ct` then preferred over their path (codetracer-pm issue
//! 2026-11-06-rust-ct-mcr-finder-ignores-ct-mcr-path.md).
//!
//! No mock is involved: the overrides are real files in a temporary
//! directory outside the workspace, and the finder is the harness's own. A
//! finder that ignored an override would provision the real sibling (a build
//! through `scripts/build-siblings.sh`) and return its `ct_cli`, or panic
//! naming that build's remedy, so the equality assertions below fail either
//! way.
//!
//! The finder reads and writes the process environment, so every case runs
//! in the one `#[test]` below, sequentially, and the environment is restored
//! between cases.

mod test_harness;

use std::env;
use std::ffi::OsString;
use std::fs;
use std::panic;
use std::path::{Path, PathBuf};

const CMD: &str = "CODETRACER_CT_MCR_CMD";
const PATH_VAR: &str = "CODETRACER_CT_MCR_PATH";

/// Set (`Some`) or remove (`None`) both override variables.
fn set_overrides(cmd: Option<&OsString>, path: Option<&OsString>) {
    for (name, value) in [(CMD, cmd), (PATH_VAR, path)] {
        // SAFETY: this binary has one test, so no other thread reads the
        // environment while it is changed.
        unsafe {
            match value {
                Some(value) => env::set_var(name, value),
                None => env::remove_var(name),
            }
        }
    }
}

/// A file standing in for a developer's own `ct-mcr`, outside the workspace.
/// The finder only checks that an override names a file; it never runs it.
fn fake_ct_mcr(dir: &Path, name: &str) -> PathBuf {
    let path = dir.join(name);
    fs::write(&path, "#!/bin/sh\nexit 0\n").expect("write the fake ct-mcr");
    path
}

#[test]
fn ct_mcr_finder_uses_ct_mcr_path_and_cmd_overrides_as_given() {
    let saved = (env::var_os(CMD), env::var_os(PATH_VAR));
    let dir = tempfile::tempdir().expect("create a temporary directory");
    assert!(
        !dir.path().starts_with(test_harness::workspace_root()),
        "the temporary directory {} must lie outside the workspace, or the finder could \
         mistake it for the sibling",
        dir.path().display()
    );
    let developer_path = fake_ct_mcr(dir.path(), "ct-mcr-via-path-var");
    let developer_cmd = fake_ct_mcr(dir.path(), "ct-mcr-via-cmd-var");

    // 1. Only CODETRACER_CT_MCR_PATH: that file, exported as
    //    CODETRACER_CT_MCR_CMD so `ct` and the backends use it too.
    set_overrides(None, Some(&developer_path.clone().into_os_string()));
    assert_eq!(test_harness::find_ct_mcr(), Some(developer_path.clone()));
    assert_eq!(env::var_os(CMD), Some(developer_path.clone().into_os_string()));

    // 2. An empty CODETRACER_CT_MCR_CMD counts as unset; it does not shadow
    //    CODETRACER_CT_MCR_PATH.
    set_overrides(Some(&OsString::new()), Some(&developer_path.clone().into_os_string()));
    assert_eq!(test_harness::find_ct_mcr(), Some(developer_path.clone()));
    assert_eq!(env::var_os(CMD), Some(developer_path.clone().into_os_string()));

    // 3. Both set: CODETRACER_CT_MCR_CMD wins, as it does in `ct`.
    set_overrides(
        Some(&developer_cmd.clone().into_os_string()),
        Some(&developer_path.clone().into_os_string()),
    );
    assert_eq!(test_harness::find_ct_mcr(), Some(developer_cmd.clone()));
    assert_eq!(env::var_os(CMD), Some(developer_cmd.clone().into_os_string()));

    // 4. A dangling CODETRACER_CT_MCR_PATH fails by name rather than being
    //    ignored in favour of a build.
    let dangling = dir.path().join("no-such-ct-mcr");
    set_overrides(None, Some(&dangling.clone().into_os_string()));
    let outcome = panic::catch_unwind(test_harness::find_ct_mcr);
    let message = match outcome {
        Ok(found) => panic!("a dangling {PATH_VAR} must fail, but the finder returned {found:?}"),
        Err(payload) => payload
            .downcast_ref::<String>()
            .cloned()
            .or_else(|| payload.downcast_ref::<&str>().map(|s| s.to_string()))
            .unwrap_or_default(),
    };
    assert!(
        message.contains(PATH_VAR) && message.contains(&dangling.display().to_string()),
        "the failure must name {PATH_VAR} and its value {}; got: {message}",
        dangling.display()
    );

    set_overrides(saved.0.as_ref(), saved.1.as_ref());
}
