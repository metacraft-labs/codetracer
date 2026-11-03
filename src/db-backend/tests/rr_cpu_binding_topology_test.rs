//! Which CPUs the harness confines an rr recording to, and how it explains a
//! counter failure, for each core topology (`test_harness/rr_cpu_binding.rs`,
//! codetracer-pm issue
//! `2026-11-01-rr-test-recordings-fail-on-e-cores-of-hybrid-hosts.md`).
//!
//! `rr_recording_hybrid_cores_test.rs` drives the binding end to end, but only
//! a hybrid host has the topology it needs. These tests read a scratch
//! directory laid out like `/sys/bus/event_source/devices` instead, because a
//! host's core topology cannot be changed by a test; `core_pmus` reads it
//! through the same path parameter it reads the real sysfs through, so the
//! only thing replaced is the directory's location.

#![cfg(target_os = "linux")]

mod test_harness;

use std::fs;
use std::path::Path;
use test_harness::rr_cpu_binding::{
    CorePmu, core_pmus, explain_rr_record_failure_on, format_cpu_list, parse_cpu_list, rr_countable_cpus,
};

const COUNTER_FAILURE: &str = "[FATAL src/PerfCounters.cc:488:check_working_counters()] \n\
                               Got 0 branch events, expected at least 500.";

/// Lay out `devices` (name, `cpus` contents or `None` for no list) as perf
/// event sources under `root`.
fn event_sources(root: &Path, devices: &[(&str, Option<&str>)]) {
    for (name, cpus) in devices {
        let dir = root.join(name);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("type"), "4\n").unwrap();
        if let Some(cpus) = cpus {
            fs::write(dir.join("cpus"), format!("{cpus}\n")).unwrap();
        }
    }
}

fn raptor_lake(root: &Path) -> Vec<CorePmu> {
    event_sources(
        root,
        &[
            ("cpu_core", Some("0-15")),
            ("cpu_atom", Some("16-31")),
            ("cstate_core", None),
            ("software", None),
            ("intel_pt", None),
        ],
    );
    core_pmus(root).unwrap()
}

fn range(a: usize, b: usize) -> Vec<usize> {
    (a..=b).collect()
}

#[test]
fn cpu_lists_parse_and_format_as_the_kernel_writes_them() {
    assert_eq!(parse_cpu_list("0-3,8,10-11\n").unwrap(), vec![0, 1, 2, 3, 8, 10, 11]);
    assert_eq!(parse_cpu_list("").unwrap(), Vec::<usize>::new());
    assert!(parse_cpu_list("3-1").is_err());
    assert!(parse_cpu_list("a-b").is_err());
    assert_eq!(format_cpu_list(&[16, 17, 18, 0, 31, 30]), "0,16-18,30-31");
}

#[test]
fn a_hybrid_host_lists_its_core_type_pmus() {
    let scratch = tempfile::tempdir().unwrap();
    assert_eq!(
        raptor_lake(scratch.path()),
        vec![
            CorePmu {
                name: "cpu_atom".into(),
                cpus: range(16, 31)
            },
            CorePmu {
                name: "cpu_core".into(),
                cpus: range(0, 15)
            },
        ]
    );
}

#[test]
fn a_hybrid_host_confines_the_recording_to_its_allowed_p_cores() {
    let scratch = tempfile::tempdir().unwrap();
    let pmus = raptor_lake(scratch.path());
    assert_eq!(rr_countable_cpus(&pmus, &range(0, 31)), Some(range(0, 15)));
    let mut e_cores_and_one_p_core = range(16, 31);
    e_cores_and_one_p_core.push(5);
    assert_eq!(rr_countable_cpus(&pmus, &e_cores_and_one_p_core), Some(vec![5]));
}

#[test]
fn a_hybrid_host_with_only_e_cores_allowed_is_left_alone_and_its_counter_failure_explained() {
    let scratch = tempfile::tempdir().unwrap();
    let pmus = raptor_lake(scratch.path());
    let e_cores = range(16, 31);
    // A hybrid-aware rr records on the E-cores, so the affinity is not taken away.
    assert_eq!(rr_countable_cpus(&pmus, &e_cores), None);
    let explanation = explain_rr_record_failure_on(COUNTER_FAILURE, &pmus, &e_cores).expect("explained");
    for needle in [
        "hybrid",
        "cpu_atom 16-31",
        "cpu_core 0-15",
        "CPUs 16-31",
        "taskset -c 0-15",
    ] {
        assert!(explanation.contains(needle), "{needle:?} missing from:\n{explanation}");
    }
}

#[test]
fn only_a_counter_failure_on_e_cores_alone_is_explained() {
    let scratch = tempfile::tempdir().unwrap();
    let pmus = raptor_lake(scratch.path());
    assert_eq!(
        explain_rr_record_failure_on("Build failed", &pmus, &range(16, 31)),
        None
    );
    // With a P-core allowed the recording was bound there, so the topology
    // does not explain a counter failure.
    assert_eq!(explain_rr_record_failure_on(COUNTER_FAILURE, &pmus, &[3, 16]), None);
}

#[test]
fn a_host_that_is_not_hybrid_is_left_alone() {
    let scratch = tempfile::tempdir().unwrap();
    // One PMU, `cpu`, which covers every CPU and lists none.
    event_sources(scratch.path(), &[("cpu", None), ("software", None)]);
    let pmus = core_pmus(scratch.path()).unwrap();
    assert!(pmus.is_empty());
    assert_eq!(rr_countable_cpus(&pmus, &range(0, 7)), None);
    assert_eq!(explain_rr_record_failure_on(COUNTER_FAILURE, &pmus, &range(0, 7)), None);
    // No event sources at all (a container without sysfs) reads as not hybrid.
    assert!(core_pmus(&scratch.path().join("missing")).unwrap().is_empty());
}

#[test]
fn a_hybrid_host_without_a_p_core_pmu_is_left_alone() {
    let scratch = tempfile::tempdir().unwrap();
    event_sources(
        scratch.path(),
        &[("cpu_atom", Some("0-3")), ("cpu_lowpower", Some("4-5"))],
    );
    let pmus = core_pmus(scratch.path()).unwrap();
    assert_eq!(rr_countable_cpus(&pmus, &range(0, 5)), None);
}
