//! Binding the harness's rr recordings to cores whose performance counter rr
//! can count on.
//!
//! Shared by two test crates, like `sibling_provisioning.rs`: db-backend's
//! harness declares it as a submodule (`test_harness/mod.rs`), and
//! backend-manager's integration tests include it with `#[path]`
//! (`src/backend-manager/tests/real_recording_integration.rs`). It uses only
//! the standard library and `libc`, which both crates depend on.
//!
//! rr measures progress by counting retired conditional branches with a
//! hardware performance counter of the core the tracee runs on, and before
//! recording it checks that counter by running 500 branches
//! (`check_working_counters` in rr's `src/PerfCounters.cc`). On an Intel
//! hybrid CPU the two core types have separate PMUs, which Linux exposes as
//! separate perf event sources: `cpu_core` for the P-cores and `cpu_atom` for
//! the E-cores (`cpu_lowpower` for the low-power E-cores of some Meteor Lake
//! and Arrow Lake parts); see
//! <https://www.kernel.org/doc/html/latest/admin-guide/perf/index.html> and
//! `arch/x86/events/intel/core.c`. An rr without hybrid support — nixpkgs'
//! rr 5.9.0 is one — derives its raw event from CPUID, which names the
//! P-core microarchitecture on every core, and programs it on whichever core
//! it runs on; on an E-core that counts nothing and rr dies with
//! `Got 0 branch events, expected at least 500`. The codetracer-rr fork that
//! ct-native-replay's dev shell stages beside it (`target/debug/rr`) counts
//! on both core types, but the harness records with whatever rr
//! ct-native-replay resolves: `$CT_RR_EXE`, then the `rr` beside it, then
//! the first `rr` on `PATH`.
//!
//! rr binds each recording to one CPU, chosen at random from its CPU
//! affinity unless `--bind-to-cpu` names one. `ct-native-replay record` does
//! not pass that option through, so the harness narrows the affinity of the
//! `ct-native-replay` child to the P-cores among the CPUs it may use, and rr
//! picks among them. The P-cores are the cores every rr counts on, a
//! hybrid-aware rr and one without hybrid support alike. On a host that is
//! not hybrid there is one PMU, and the affinity is left alone.
//!
//! When the affinity the harness was given contains no P-core at all (a run
//! confined with `taskset` to the E-cores) it is left alone too: a
//! hybrid-aware rr records there. If the rr in use cannot, its counter error
//! reads as a broken host or a broken test, so
//! [`explain_rr_record_failure`] adds the host's core topology and the
//! remedy to it (codetracer-pm issue
//! `2026-11-01-rr-test-recordings-fail-on-e-cores-of-hybrid-hosts.md`).

#![allow(dead_code)]

use std::path::Path;
use std::process::Command;

/// Where Linux lists the perf event sources, one directory per PMU.
pub const EVENT_SOURCES: &str = "/sys/bus/event_source/devices";

/// The perf event source of the P-cores on an Intel hybrid CPU.
const P_CORE_PMU: &str = "cpu_core";

/// A core-type PMU and the CPUs it covers, e.g. `cpu_atom` and `16-31`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CorePmu {
    pub name: String,
    pub cpus: Vec<usize>,
}

/// Parse a Linux CPU list, as sysfs writes it and `taskset -c` reads it
/// (`0-15,32`): <https://www.kernel.org/doc/html/latest/admin-guide/cputopology.html>.
pub fn parse_cpu_list(text: &str) -> Result<Vec<usize>, String> {
    let parse = |n: &str| {
        n.trim()
            .parse::<usize>()
            .map_err(|e| format!("bad CPU number {n:?} in CPU list {text:?}: {e}"))
    };
    let mut cpus = Vec::new();
    for part in text.trim().split(',').filter(|p| !p.trim().is_empty()) {
        match part.split_once('-') {
            Some((first, last)) => {
                let (first, last) = (parse(first)?, parse(last)?);
                if first > last {
                    return Err(format!("descending range {part:?} in CPU list {text:?}"));
                }
                cpus.extend(first..=last);
            }
            None => cpus.push(parse(part)?),
        }
    }
    cpus.sort_unstable();
    cpus.dedup();
    Ok(cpus)
}

/// Format CPUs as a Linux CPU list, collapsing runs into ranges.
pub fn format_cpu_list(cpus: &[usize]) -> String {
    let mut sorted = cpus.to_vec();
    sorted.sort_unstable();
    sorted.dedup();
    let mut parts = Vec::new();
    let mut i = 0;
    while i < sorted.len() {
        let mut j = i;
        while j + 1 < sorted.len() && sorted[j + 1] == sorted[j] + 1 {
            j += 1;
        }
        parts.push(if i == j {
            sorted[i].to_string()
        } else {
            format!("{}-{}", sorted[i], sorted[j])
        });
        i = j + 1;
    }
    parts.join(",")
}

/// The core-type PMUs under `event_sources` (normally [`EVENT_SOURCES`]):
/// the `cpu_*` event sources that list the CPUs they cover. A non-hybrid
/// host has none (its PMU is `cpu`, which covers every CPU and lists none),
/// and an Intel hybrid host has `cpu_core` plus one or two E-core types.
/// Sorted by name. A missing directory reads as no PMUs.
pub fn core_pmus(event_sources: &Path) -> Result<Vec<CorePmu>, String> {
    let entries = match std::fs::read_dir(event_sources) {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(format!("cannot list {}: {e}", event_sources.display())),
    };
    let mut pmus = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|e| format!("cannot list {}: {e}", event_sources.display()))?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if !name.starts_with("cpu_") {
            continue;
        }
        let cpus_file = entry.path().join("cpus");
        let text = match std::fs::read_to_string(&cpus_file) {
            Ok(text) => text,
            // `cpu_*` sources without a CPU list are not core types.
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
            Err(e) => return Err(format!("cannot read {}: {e}", cpus_file.display())),
        };
        pmus.push(CorePmu {
            name,
            cpus: parse_cpu_list(&text).map_err(|e| format!("{}: {e}", cpus_file.display()))?,
        });
    }
    pmus.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(pmus)
}

/// The P-core PMU of a hybrid host, or `None` when `pmus` (from
/// [`core_pmus`]) is not an Intel hybrid with a P-core PMU and at least one
/// other core type.
fn hybrid_p_cores(pmus: &[CorePmu]) -> Option<&CorePmu> {
    if pmus.len() < 2 {
        return None;
    }
    pmus.iter().find(|pmu| pmu.name == P_CORE_PMU)
}

/// The CPUs, out of `allowed`, that an rr recording should be confined to:
/// the allowed P-cores of a hybrid host. `None` leaves the affinity alone:
/// the host is not hybrid, or no allowed CPU is a P-core.
pub fn rr_countable_cpus(pmus: &[CorePmu], allowed: &[usize]) -> Option<Vec<usize>> {
    let p_cores = hybrid_p_cores(pmus)?;
    let countable: Vec<usize> = allowed
        .iter()
        .copied()
        .filter(|cpu| p_cores.cpus.contains(cpu))
        .collect();
    (!countable.is_empty()).then_some(countable)
}

/// The explanation to add to a failed rr recording's error, given the
/// failure's output, the host's core PMUs and the CPUs the recording was
/// allowed: `Some` when rr reported a counter that does not count (its
/// `check_working_counters` message) on a hybrid host while no allowed CPU
/// was a P-core, naming the core topology, the allowed CPUs and the remedy;
/// `None` otherwise.
pub fn explain_rr_record_failure_on(output: &str, pmus: &[CorePmu], allowed: &[usize]) -> Option<String> {
    if !output.contains("branch events, expected at least") {
        return None;
    }
    let p_cores = hybrid_p_cores(pmus)?;
    // With a P-core allowed, the recording was bound to the P-cores, so a
    // counter that does not count there is not explained by the topology.
    if allowed.iter().any(|cpu| p_cores.cpus.contains(cpu)) {
        return None;
    }
    let topology = pmus
        .iter()
        .map(|pmu| format!("{} {}", pmu.name, format_cpu_list(&pmu.cpus)))
        .collect::<Vec<_>>()
        .join(", ");
    Some(format!(
        "this host is a hybrid CPU whose core types have separate performance-counter PMUs ({topology}). \
         The recording could run only on CPUs {}, none of them a P-core ({P_CORE_PMU}), and the rr it used \
         cannot count on the other core types. Allow at least one {P_CORE_PMU} CPU (e.g. `taskset -c {}`), \
         or record with an rr that supports hybrid CPUs (the codetracer-rr fork ct-native-replay's dev shell \
         stages as target/debug/rr).",
        format_cpu_list(allowed),
        format_cpu_list(&p_cores.cpus),
    ))
}

/// [`explain_rr_record_failure_on`] for this host and the CPUs the calling
/// thread may run on. `None` also when either cannot be read: the
/// explanation is an addition to an error, never a second one.
pub fn explain_rr_record_failure(output: &str) -> Option<String> {
    let pmus = core_pmus(Path::new(EVENT_SOURCES)).ok()?;
    explain_rr_record_failure_on(output, &pmus, &current_affinity().ok()?)
}

/// The CPUs the calling thread may run on, which a child it spawns inherits.
pub fn current_affinity() -> Result<Vec<usize>, String> {
    // SAFETY: sched_getaffinity(2) on the calling thread (pid 0) with a
    // zero-initialised cpu_set_t of the size passed.
    unsafe {
        let mut set: libc::cpu_set_t = std::mem::zeroed();
        if libc::sched_getaffinity(0, std::mem::size_of::<libc::cpu_set_t>(), &mut set) != 0 {
            return Err(format!("sched_getaffinity: {}", std::io::Error::last_os_error()));
        }
        Ok((0..libc::CPU_SETSIZE as usize)
            .filter(|&cpu| libc::CPU_ISSET(cpu, &set))
            .collect())
    }
}

/// Confine `command`, which makes an rr recording (`ct-native-replay record`
/// with the rr backend), to the CPUs every rr can count on: on a hybrid host,
/// the P-cores among the CPUs this thread may run on. Leaves `command` alone
/// on any other host, and when no allowed CPU is a P-core. See the module
/// documentation.
pub fn bind_rr_recording_to_countable_cores(command: &mut Command) -> Result<(), String> {
    let pmus = core_pmus(Path::new(EVENT_SOURCES))?;
    let Some(cpus) = rr_countable_cpus(&pmus, &current_affinity()?) else {
        return Ok(());
    };
    // Built before the fork: the pre_exec hook runs between fork and exec,
    // where only async-signal-safe calls such as sched_setaffinity(2) are
    // allowed.
    // SAFETY: zero-initialised cpu_set_t; CPU_SET only on CPUs that came
    // from a cpu_set_t, so all below CPU_SETSIZE.
    let set = unsafe {
        let mut set: libc::cpu_set_t = std::mem::zeroed();
        for &cpu in &cpus {
            libc::CPU_SET(cpu, &mut set);
        }
        set
    };
    // SAFETY: the hook only calls sched_setaffinity(2) on the child itself.
    unsafe {
        use std::os::unix::process::CommandExt;
        command.pre_exec(move || {
            if libc::sched_setaffinity(0, std::mem::size_of::<libc::cpu_set_t>(), &set) != 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    Ok(())
}

/// The error for a failed rr recording: `error`, followed by
/// [`explain_rr_record_failure`]'s explanation of `output` when it has one.
pub fn with_rr_record_failure_explained(error: String, output: &str) -> String {
    match explain_rr_record_failure(output) {
        Some(explanation) => format!("{error}\n\n{explanation}"),
        None => error,
    }
}
