//! Guard: nothing in this crate may read the clock through `std::time`.
//!
//! `SystemTime::now()` and `Instant::now()` are unimplemented on
//! `wasm32-unknown-unknown`. The std implementation is a `panic!` that
//! compiles to an `unreachable` trap, so a single such call on a reachable
//! path **kills the browser worker** — no unwinding, no DAP response, and the
//! renderer's future hangs forever with nothing in any log.
//!
//! Three replay surfaces were observed dying exactly this way in the browser:
//!
//!   * `ct/load-locals`  → `WallClockDeadline::new` (`origin_query.rs`)
//!   * `ct/originChain`  → the same deadline, via every origin backend
//!   * any step reaching a trace boundary → `Notification::new` (`task.rs`)
//!
//! All of them now read [`db_backend::wall_clock`] instead. This test exists
//! because fixing three observed call sites is not the same as fixing the
//! class: the next one would be found by a user, not by a probe. It fails
//! the moment a raw `std::time` clock read appears in a new place.
//!
//! **If this test fails, the fix is to call `crate::wall_clock` — not to add
//! an entry below.** An allowlist entry is only correct when the code is
//! provably absent from the wasm build, and the `reason` must say why.
//!
//! A tempting stronger check — grep the linked `.wasm` for std's
//! `time not implemented on this platform` panic string — does NOT work, and
//! is recorded here so nobody spends an afternoon rediscovering it: that
//! string is present in the `.wasm` both before and after this fix, because
//! `std::sync::mpmc::Channel::send` (the DAP response channel) contains a
//! guarded `Instant::now()` on its `deadline: Some(_)` path. Our `send`
//! always passes `None`, so it is unreachable — but the string is linked
//! regardless and the check cannot tell the two apart. Source-level is the
//! precise level for this; the runtime evidence is the browser probe, which
//! drives the real wasm engine through `ct/load-locals`, boundary stepping,
//! `ct/originChain` and `disconnect`.

use std::path::{Path, PathBuf};

/// Clock reads that are forbidden outside the shim.
const FORBIDDEN: &[&str] = &[
    "SystemTime::now",
    "Instant::now",
    // `chrono` has its own wall clock with the same wasm hazard.
    "Local::now",
    "Utc::now",
];

/// A file allowed to contain raw clock reads, with the number expected and
/// the reason the wasm build never sees them.
struct Exemption {
    /// Path relative to `src/db-backend`.
    path: &'static str,
    /// Exact number of non-comment occurrences expected. An exact count (not
    /// a ceiling) so that *adding* one to an already-exempt file also fails.
    occurrences: usize,
    reason: &'static str,
}

const EXEMPTIONS: &[Exemption] = &[
    Exemption {
        path: "src/wall_clock.rs",
        occurrences: 2,
        reason: "the shim itself — both reads are inside `#[cfg(not(target_arch = \"wasm32\"))]`",
    },
    Exemption {
        path: "src/main.rs",
        occurrences: 1,
        reason: "the `replay-server` binary has `required-features = [\"io-transport\"]`, \
                 so it is not part of any wasm build (Cargo.toml `[[bin]]`)",
    },
    Exemption {
        path: "src/recreator_session.rs",
        occurrences: 4,
        reason: "every read is inside a `#[cfg(unix)]` or `#[cfg(windows)]` item; \
                 wasm32-unknown-unknown is neither, so they are not compiled in \
                 (verified: `cargo check --target wasm32-unknown-unknown` reports \
                 `unused import: Instant` for this file)",
    },
    Exemption {
        path: "src/ctfs_trace_reader/mod.rs",
        occurrences: 6,
        reason: "all inside the `#[cfg(test)]` performance-bench module, which is \
                 never part of a `cargo build --target wasm32-unknown-unknown`",
    },
];

/// Strip line comments so the prose in this repo's (numerous) explanatory
/// comments about `SystemTime::now()` does not count as a call.
///
/// Deliberately naive: it does not understand `/* */` or string literals.
/// Erring toward counting too much is the safe direction — a false positive
/// is a visible test failure, a false negative is a dead worker.
fn strip_line_comments(source: &str) -> String {
    source
        .lines()
        .map(|line| match line.find("//") {
            Some(idx) => &line[..idx],
            None => line,
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn crate_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn rust_sources(dir: &Path, out: &mut Vec<PathBuf>) {
    let entries = std::fs::read_dir(dir).unwrap_or_else(|e| panic!("read_dir {}: {e}", dir.display()));
    for entry in entries {
        let entry = entry.expect("dir entry");
        let path = entry.path();
        if path.is_dir() {
            rust_sources(&path, out);
        } else if path.extension().is_some_and(|e| e == "rs") {
            out.push(path);
        }
    }
}

fn occurrences(source: &str) -> usize {
    let code = strip_line_comments(source);
    FORBIDDEN.iter().map(|needle| code.matches(needle).count()).sum()
}

#[test]
fn no_module_reads_the_clock_outside_the_wall_clock_shim() {
    let root = crate_root();
    let mut sources = Vec::new();
    rust_sources(&root.join("src"), &mut sources);
    assert!(
        sources.len() > 20,
        "the sweep found only {} source files — it is not actually scanning the crate",
        sources.len(),
    );

    let mut offenders: Vec<String> = Vec::new();
    for path in &sources {
        let relative = path
            .strip_prefix(&root)
            .unwrap_or(path)
            .to_string_lossy()
            .replace('\\', "/");
        let source = std::fs::read_to_string(path).unwrap_or_else(|e| panic!("read {relative}: {e}"));
        let found = occurrences(&source);
        if found == 0 {
            continue;
        }
        match EXEMPTIONS.iter().find(|e| e.path == relative) {
            Some(exemption) if exemption.occurrences == found => {}
            Some(exemption) => offenders.push(format!(
                "{relative}: {found} raw clock reads, but the allowlist expects {} \
                 ({}). If the new read is genuinely unreachable from wasm, update the \
                 count AND the reason; otherwise call `crate::wall_clock`.",
                exemption.occurrences, exemption.reason,
            )),
            None => offenders.push(format!(
                "{relative}: {found} raw clock read(s). `SystemTime::now()` / \
                 `Instant::now()` trap on wasm32-unknown-unknown and kill the browser \
                 worker; call `crate::wall_clock::{{monotonic_ms, unix_seconds}}` instead."
            )),
        }
    }

    assert!(
        offenders.is_empty(),
        "raw std::time clock reads found:\n  {}",
        offenders.join("\n  "),
    );
}

/// The allowlist must not rot: an entry naming a file that no longer exists
/// (or that no longer reads the clock) is a stale exemption that would hide
/// a future regression in a file re-created under the same name.
#[test]
fn every_exemption_is_still_load_bearing() {
    let root = crate_root();
    for exemption in EXEMPTIONS {
        let path = root.join(exemption.path);
        assert!(
            path.exists(),
            "allowlisted {} no longer exists — drop the exemption",
            exemption.path,
        );
        let source = std::fs::read_to_string(&path).expect("read allowlisted file");
        assert_eq!(
            occurrences(&source),
            exemption.occurrences,
            "allowlisted {} now has a different number of clock reads",
            exemption.path,
        );
        assert!(
            !exemption.reason.trim().is_empty(),
            "{} is exempt with no stated reason",
            exemption.path,
        );
    }
}

/// The three surfaces the browser probe found dead must be clean, named
/// individually so a regression report says *which* feature broke rather
/// than just "the sweep failed".
#[test]
fn the_three_observed_browser_traps_stay_fixed() {
    let root = crate_root();
    for (path, surface) in [
        (
            "src/origin_query.rs",
            "ct/load-locals and ct/originChain (WallClockDeadline)",
        ),
        (
            "src/task.rs",
            "trace-boundary stepping (Notification::new) and Stop::new",
        ),
        ("src/db.rs", "ct/load-history value stamps"),
    ] {
        let source = std::fs::read_to_string(root.join(path)).expect("read source");
        assert_eq!(
            occurrences(&source),
            0,
            "{path} reads the clock through std::time again — this breaks {surface} \
             in the browser by trapping the worker with no response ever sent",
        );
    }
}

/// The shim must expose both shapes. A "fix" that deleted `monotonic_ms` and
/// left every deadline measuring zero would otherwise pass silently.
#[test]
fn the_shim_offers_both_a_duration_source_and_a_timestamp_source() {
    let source = std::fs::read_to_string(crate_root().join("src/wall_clock.rs")).expect("read wall_clock.rs");
    assert!(source.contains("pub fn monotonic_ms() -> u64"));
    assert!(source.contains("pub fn unix_seconds() -> u64"));
    assert!(
        source.contains("target_arch = \"wasm32\""),
        "the shim must be platform-conditional, or it is not a fix at all",
    );
}
