//! The prerequisite probe asks Go for its version the way Go supports.
//!
//! Contract: codetracer-specs
//! `spec/Testing/Native-Go-Prerequisite-Version-Probe.md`.
//!
//! `test_harness::probe_command` used to invoke every executable with
//! `--version`. Go has no `--version` flag: `go --version` exits 2 while
//! `go version` exits 0. So an installed, working Go was classified
//! [`CommandProbe::Broken`], `is_command_available("go")` panicked, and the Go
//! integration targets (`go_flow_integration`, the Go MCR flow tests) refused
//! before recording anything.
//!
//! # What this file grades
//!
//! The probe against its real subject, in all three of its states:
//!
//! * **Usable** — the real `go` on PATH, and the same executable named by its
//!   explicit absolute path (the basename, not the PATH lookup, selects the
//!   argv).
//! * **Absent** — an explicit `go` path inside an existing directory that
//!   holds no such file.
//! * **Broken** — GNU `false`, which is still probed with `--version` and
//!   still fails (other tools' argv is unchanged); and the real `go`, made to
//!   fail its own `version` subcommand by asking it to switch to a toolchain
//!   it cannot obtain (`GOTOOLCHAIN=go1.999.0`, `GOPROXY=off`). This is the
//!   hard refusal for a present failing tool: the diagnosis must name the
//!   argv actually invoked, and `is_command_available` must still panic.
//!
//! A negative control shows the subject is the one the defect was about: the
//! same real `go` exits non-zero for `--version`. Without it, a Usable result
//! would not show that the argv selection mattered.
//!
//! # No mocks
//!
//! None are used. Every probed executable is real: the Go toolchain the dev
//! shell provides, and GNU coreutils `false`. There is no stand-in script, no
//! PATH replacement and no fake `go`; the failing-Go control fails inside the
//! real `go` binary.
//!
//! # Why a single `#[test]`
//!
//! The Broken control sets `GOTOOLCHAIN` / `GOPROXY` in this process's
//! environment, which `probe_command` (by design: it takes only a command
//! name) passes on to the child. Process environment is shared by every test
//! thread in the binary, so the arms run in sequence inside one test and the
//! variables are restored before it returns. Nothing else in this binary
//! reads them.
//!
//! # Prerequisite
//!
//! A host with no `go` on PATH takes the harness's graceful skip, which
//! `CODETRACER_ALLOW_GRACEFUL_TEST_SKIPPING=false` turns into a failure. The
//! lookup that decides this walks PATH directly, so it does not depend on the
//! probe under test.

mod test_harness;

use std::env;
use std::ffi::OsString;
use std::path::PathBuf;
use std::process::Command;
use test_harness::{CommandProbe, is_command_available, probe_command};

/// The first `go` (`go.exe` on Windows) on PATH, found without running it.
fn find_go_on_path() -> Option<PathBuf> {
    let name = if cfg!(windows) { "go.exe" } else { "go" };
    env::split_paths(&env::var_os("PATH")?)
        .map(|dir| dir.join(name))
        .find(|candidate| candidate.is_file())
}

/// Set (or, with `None`, remove) an environment variable for the duration of
/// one arm, and put the previous value back on drop — including when the arm
/// panics.
struct EnvOverride {
    key: &'static str,
    previous: Option<OsString>,
}

impl EnvOverride {
    fn set(key: &'static str, value: Option<&str>) -> Self {
        let previous = env::var_os(key);
        // SAFETY: this binary has a single test function, so no other thread
        // reads or writes the environment while the override is live.
        unsafe {
            match value {
                Some(v) => env::set_var(key, v),
                None => env::remove_var(key),
            }
        }
        EnvOverride { key, previous }
    }
}

impl Drop for EnvOverride {
    fn drop(&mut self) {
        // SAFETY: as in `EnvOverride::set`.
        unsafe {
            match &self.previous {
                Some(v) => env::set_var(self.key, v),
                None => env::remove_var(self.key),
            }
        }
    }
}

/// `is_command_available(cmd)` must refuse a present, failing tool by panicking
/// with the harness's refusal, never return `false` (which would be a skip).
fn assert_refused(cmd: &str) {
    let refused = std::panic::catch_unwind(|| is_command_available(cmd));
    let payload = refused.expect_err("a present, failing tool must panic, not skip");
    let message = payload
        .downcast_ref::<String>()
        .cloned()
        .or_else(|| payload.downcast_ref::<&str>().map(|s| s.to_string()))
        .unwrap_or_default();
    assert!(
        message.contains("PREREQUISITE PRESENT BUT BROKEN"),
        "unexpected refusal for `{cmd}`: {message}"
    );
}

#[test]
fn native_go_prerequisite_probe_uses_the_supported_version_command() {
    // ---- every other tool keeps `--version`, and a failing one is Broken --
    // GNU coreutils' `false` exits 1 even for `--version` (documented in
    // https://www.gnu.org/software/coreutils/manual/html_node/false-invocation.html),
    // so it is a real, present, genuinely failing executable. The diagnosis
    // must name `false --version`: the Go change must not touch other tools'
    // argv, and must not soften the refusal for a present failing tool.
    #[cfg(unix)]
    {
        match probe_command("false") {
            CommandProbe::Broken(why) => assert!(
                why.contains("`false --version` exited"),
                "a non-Go tool must still be probed with --version: {why}"
            ),
            other => panic!("`false --version` must be Broken, got {other:?}"),
        }
        assert_refused("false");
    }

    let Some(go) = find_go_on_path() else {
        test_harness::skip_or_fail_missing_prerequisite(
            "native_go_prerequisite_probe_uses_the_supported_version_command",
            "go is not on PATH",
            "run inside the codetracer dev shell, which provides it, or install it",
        );
        return;
    };
    let go_path = go.to_str().expect("PATH entry for go is UTF-8").to_string();

    // Neutralise any ambient toolchain-switch request for the positive arms,
    // so they grade the probe and not the caller's environment.
    let _toolchain = EnvOverride::set("GOTOOLCHAIN", Some("local"));

    // ---- negative control: the real subject rejects `--version` ----------
    let dashed = Command::new(&go).arg("--version").output().expect("run go --version");
    assert!(
        !dashed.status.success(),
        "control: `{go_path} --version` succeeded, so this Go does not exhibit the defect \
         and the positive arms below would not show that argv selection matters"
    );
    let plain = Command::new(&go).arg("version").output().expect("run go version");
    assert!(plain.status.success(), "control: `{go_path} version` failed: {plain:?}");
    assert!(
        String::from_utf8_lossy(&plain.stdout).starts_with("go version go"),
        "control: unexpected `go version` output: {:?}",
        String::from_utf8_lossy(&plain.stdout)
    );

    // ---- Usable: bare name on PATH and the explicit path -----------------
    assert_eq!(probe_command("go"), CommandProbe::Usable, "bare `go` on PATH");
    assert_eq!(probe_command(&go_path), CommandProbe::Usable, "explicit {go_path}");
    assert!(is_command_available("go"));
    assert!(is_command_available(&go_path));

    // ---- Absent: an explicit go path that does not exist -----------------
    let empty_dir = env::temp_dir().join(format!("ct-go-probe-absent-{}", std::process::id()));
    std::fs::create_dir_all(&empty_dir).expect("create scratch dir");
    let missing = empty_dir.join(if cfg!(windows) { "go.exe" } else { "go" });
    assert!(!missing.exists());
    let missing_str = missing.to_str().unwrap().to_string();
    assert_eq!(probe_command(&missing_str), CommandProbe::Absent);
    assert!(!is_command_available(&missing_str));
    let _ = std::fs::remove_dir(&empty_dir);

    // ---- Broken: the real go failing its own `version` subcommand --------
    {
        let _toolchain = EnvOverride::set("GOTOOLCHAIN", Some("go1.999.0"));
        let _proxy = EnvOverride::set("GOPROXY", Some("off"));
        let direct = Command::new(&go).arg("version").output().expect("run go version");
        assert!(
            !direct.status.success(),
            "control: GOTOOLCHAIN=go1.999.0 GOPROXY=off did not make `go version` fail, \
             so the Broken arm would not exercise a failing tool: {direct:?}"
        );

        for cmd in ["go", go_path.as_str()] {
            match probe_command(cmd) {
                CommandProbe::Broken(why) => assert!(
                    why.contains(&format!("`{cmd} version` exited")),
                    "Broken diagnosis must name the argv actually invoked: {why}"
                ),
                other => panic!("a failing `{cmd} version` must be Broken, got {other:?}"),
            }
            assert_refused(cmd);
        }
    }

    // The overrides are dropped: the probe is Usable again.
    assert_eq!(probe_command("go"), CommandProbe::Usable);
}
