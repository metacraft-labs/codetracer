//! An rr recording made by the test harness must land on a core whose
//! performance counter rr can count on, on a hybrid (P-core + E-core) host.
//!
//! codetracer-pm issue
//! `2026-11-01-rr-test-recordings-fail-on-e-cores-of-hybrid-hosts.md`. rr
//! counts retired conditional branches with the performance counter of the
//! core the tracee runs on. On an Intel hybrid CPU the E-cores' PMU
//! (`cpu_atom`) is a different PMU from the P-cores' (`cpu_core`), and an rr
//! without hybrid support (nixpkgs' rr 5.9.0) programs the P-core event on
//! whichever core it picks. rr picks a random core out of its CPU affinity,
//! so on an i9-13900K (P-cores 0-15, E-cores 16-31) about half of the
//! recordings died with `Got 0 branch events, expected at least 500`, each
//! failure reading as a failure of the test that asked for the recording.
//!
//! The harness records with whatever rr `ct-native-replay` resolves:
//! `$CT_RR_EXE`, then the `rr` beside it (the hybrid-aware codetracer-rr fork
//! its dev shell stages), then `PATH`. This test pins the rr the issue was
//! measured with, rr 5.9.0 from codetracer's locked nixpkgs, through
//! `$CT_RR_EXE`, so it exercises the harness against an rr that cannot count
//! on the E-cores whatever the workspace stages.
//!
//! It recreates the issue's conditions deterministically by narrowing the
//! CPU affinity the harness inherits (affinity is per thread on Linux, and a
//! spawned child inherits its spawning thread's), and records a real C
//! program through `TestRecording::create`, the harness entry point the
//! db-backend rr tests use:
//!
//! * every E-core plus a single P-core: unbound, rr lands on an E-core 16
//!   times in 17; the harness must bind the recording to the P-core, so
//!   every recording succeeds.
//! * no P-core at all: rr cannot count anywhere it may run, and the error
//!   must name the host's core topology and the remedy rather than leave rr's
//!   counter error to read as a broken host or a broken test.
//!
//! Both need a hybrid host. On any other host the condition they recreate
//! does not exist (there is no second PMU to land on), so the test says so on
//! stderr and passes; `rr_cpu_binding_topology_test.rs` covers the selection
//! logic on every host.
//!
//! The scenarios share one `#[test]` because `$CT_RR_EXE` is process-wide:
//! it is set once, before this binary spawns anything, and this binary has
//! no other test to race with it.
//!
//! No mocks: a real program is built and recorded by the real
//! `ct-native-replay` and a real rr.

#![cfg(target_os = "linux")]

mod test_harness;

use std::path::{Path, PathBuf};
use std::process::Command;
use test_harness::{Language, TestRecording};

const EVENT_SOURCES: &str = "/sys/bus/event_source/devices";

/// Parse a Linux CPU list (`0-15,32`), as sysfs and `taskset -c` write it.
/// Kept independent of the harness's parser, which is under test.
fn cpu_list(text: &str) -> Vec<usize> {
    let mut cpus = Vec::new();
    for part in text.trim().split(',').filter(|p| !p.is_empty()) {
        match part.split_once('-') {
            Some((a, b)) => cpus.extend(a.parse::<usize>().unwrap()..=b.parse::<usize>().unwrap()),
            None => cpus.push(part.parse().unwrap()),
        }
    }
    cpus
}

/// The host's P-cores and E-cores, read independently of the harness, or
/// `None` when the host is not an Intel hybrid.
fn hybrid_cores() -> Option<(Vec<usize>, Vec<usize>)> {
    let read = |pmu: &str| std::fs::read_to_string(Path::new(EVENT_SOURCES).join(pmu).join("cpus")).ok();
    Some((cpu_list(&read("cpu_core")?), cpu_list(&read("cpu_atom")?)))
}

/// Restricts the calling thread to `cpus` until dropped, then restores the
/// affinity it had.
struct ThreadAffinity(libc::cpu_set_t);

impl ThreadAffinity {
    fn restrict_to(cpus: &[usize]) -> Self {
        // SAFETY: plain sched_{get,set}affinity(2) on the calling thread with
        // a correctly sized, zero-initialised cpu_set_t.
        unsafe {
            let mut saved: libc::cpu_set_t = std::mem::zeroed();
            assert_eq!(
                libc::sched_getaffinity(0, std::mem::size_of::<libc::cpu_set_t>(), &mut saved),
                0,
                "sched_getaffinity: {}",
                std::io::Error::last_os_error()
            );
            let mut set: libc::cpu_set_t = std::mem::zeroed();
            for &cpu in cpus {
                libc::CPU_SET(cpu, &mut set);
            }
            assert_eq!(
                libc::sched_setaffinity(0, std::mem::size_of::<libc::cpu_set_t>(), &set),
                0,
                "sched_setaffinity({cpus:?}): {}",
                std::io::Error::last_os_error()
            );
            ThreadAffinity(saved)
        }
    }
}

impl Drop for ThreadAffinity {
    fn drop(&mut self) {
        // SAFETY: as in `restrict_to`.
        unsafe {
            libc::sched_setaffinity(0, std::mem::size_of::<libc::cpu_set_t>(), &self.0);
        }
    }
}

/// rr 5.9.0 from codetracer's locked nixpkgs: the rr without hybrid support
/// the issue was measured with. Supplied, never skipped: a host without nix
/// fails here, naming the command.
fn rr_without_hybrid_support() -> PathBuf {
    let root = test_harness::codetracer_root();
    let output = Command::new("nix")
        .args(["build", "--no-link", "--print-out-paths", "--inputs-from"])
        .arg(&root)
        .arg("nixpkgs#rr")
        .output()
        .unwrap_or_else(|e| {
            panic!(
                "cannot run `nix build --inputs-from {} nixpkgs#rr`: {e}",
                root.display()
            )
        });
    assert!(
        output.status.success(),
        "`nix build --inputs-from {} nixpkgs#rr` failed:\n{}",
        root.display(),
        String::from_utf8_lossy(&output.stderr)
    );
    let out = String::from_utf8_lossy(&output.stdout);
    let rr = PathBuf::from(out.lines().last().expect("nix build printed the out path").trim()).join("bin/rr");
    assert!(rr.is_file(), "{} is not a file", rr.display());
    rr
}

fn c_program() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("test-programs/c/c_flow_test.c")
}

#[test]
fn rr_recordings_on_a_hybrid_host_use_a_core_rr_counts_on() {
    let Some((p_cores, e_cores)) = hybrid_cores() else {
        eprintln!("not a hybrid host: no cpu_core + cpu_atom PMUs under {EVENT_SOURCES}; nothing to recreate");
        return;
    };
    let rr = rr_without_hybrid_support();
    // SAFETY: the only test in this binary sets it before spawning anything,
    // so no other thread reads the environment concurrently.
    unsafe { std::env::set_var("CT_RR_EXE", &rr) };
    let ct_native_replay = test_harness::find_ct_native_replay().expect("ct-native-replay is provisioned");

    // Every E-core plus one P-core. Unbound, each recording lands on an
    // E-core with probability 16/17 on the 13900K, so four in a row on the
    // P-core by chance is ~1 in 80 000.
    {
        let mut allowed = e_cores.clone();
        allowed.push(p_cores[0]);
        let _affinity = ThreadAffinity::restrict_to(&allowed);
        for attempt in 0..4 {
            let recording = TestRecording::create(
                &c_program(),
                Language::C,
                &format!("hybrid{attempt}"),
                &ct_native_replay,
            );
            if let Err(err) = recording {
                panic!(
                    "recording {attempt} with {} failed, CPUs {allowed:?} allowed (P-core {}, E-cores {e_cores:?}):\n{err}",
                    rr.display(),
                    p_cores[0]
                );
            }
        }
    }

    // No P-core: rr cannot count anywhere it may run. The error must say why.
    {
        let _affinity = ThreadAffinity::restrict_to(&e_cores);
        let err = match TestRecording::create(&c_program(), Language::C, "ecores", &ct_native_replay) {
            Ok(_) => panic!(
                "{} recorded on the E-cores {e_cores:?}; it was expected to lack hybrid support",
                rr.display()
            ),
            Err(err) => err,
        };
        for needle in ["hybrid", "cpu_core", "cpu_atom", "taskset -c"] {
            assert!(
                err.contains(needle),
                "the error must name the host's core topology and the remedy ({needle:?} missing):\n{err}"
            );
        }
    }
}
